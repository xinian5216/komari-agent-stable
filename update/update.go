package update

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/blang/semver"
	goUpdate "github.com/inconshreveable/go-update"
	"github.com/komari-monitor/komari-agent/dnsresolver"
)

var (
	CurrentVersion string = "0.0.1"
	// Repo is the GitHub repository the agent self-updates from.
	// Komari Stable maintains its own mirror, so the default points at the fork;
	// it can still be overridden at build time via -ldflags.
	Repo string = "xinian5216/komari-agent-stable"
)

const (
	snapshotVersionPrefix = "Snapshot-"
)

// The GitHub endpoint and the container marker are variables so that tests can
// point them at a local server or a temporary marker file.
var (
	githubAPIBaseURL    = "https://api.github.com"
	containerMarkerPath = "/.komari-agent-container"
)

type buildTrack int

const (
	stableTrack buildTrack = iota
	snapshotTrack
)

type githubRelease struct {
	TagName     string               `json:"tag_name"`
	Name        string               `json:"name"`
	Body        string               `json:"body"`
	Draft       bool                 `json:"draft"`
	Prerelease  bool                 `json:"prerelease"`
	HTMLURL     string               `json:"html_url"`
	PublishedAt time.Time            `json:"published_at"`
	Assets      []githubReleaseAsset `json:"assets"`
}

type githubReleaseAsset struct {
	ID                 int64  `json:"id"`
	Name               string `json:"name"`
	Size               int    `json:"size"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

// snapshotReleaseCandidate is a resolved release that can be installed on this
// platform. It is shared by the stable and the snapshot update track.
type snapshotReleaseCandidate struct {
	TagName     string
	Name        string
	Body        string
	HTMLURL     string
	PublishedAt time.Time
	Asset       githubReleaseAsset
	Source      githubRelease
}

// parseVersion 解析可能带有 v/V 前缀，以及预发布或构建元数据的版本字符串
func parseVersion(ver string) (semver.Version, error) {
	ver = strings.TrimPrefix(ver, "v")
	ver = strings.TrimPrefix(ver, "V")
	return semver.ParseTolerant(ver)
}

// needUpdate 判断是否需要更新
func needUpdate(current, latest semver.Version) bool {
	// 返回最新版本大于当前版本时需要更新
	return latest.Compare(current) > 0
}

func detectBuildTrack(version string) buildTrack {
	if strings.HasPrefix(version, snapshotVersionPrefix) {
		return snapshotTrack
	}
	return stableTrack
}

func expectedAssetName(goos, goarch string) string {
	name := fmt.Sprintf("komari-agent-%s-%s", goos, goarch)
	if goos == "windows" {
		name += ".exe"
	}
	return name
}

func findReleaseAsset(release githubRelease, assetName string) (githubReleaseAsset, bool) {
	for _, asset := range release.Assets {
		if asset.Name == assetName {
			return asset, true
		}
	}
	return githubReleaseAsset{}, false
}

// selectLatestSnapshotRelease picks the newest snapshot (prerelease) build that
// carries the asset for this platform.
func selectLatestSnapshotRelease(releases []githubRelease, assetName string) (snapshotReleaseCandidate, bool) {
	var latest snapshotReleaseCandidate
	found := false

	for _, release := range releases {
		if release.Draft || !release.Prerelease || !strings.HasPrefix(release.TagName, snapshotVersionPrefix) {
			continue
		}

		asset, ok := findReleaseAsset(release, assetName)
		if !ok {
			continue
		}

		candidate := snapshotReleaseCandidate{
			TagName:     release.TagName,
			Name:        release.Name,
			Body:        release.Body,
			HTMLURL:     release.HTMLURL,
			PublishedAt: release.PublishedAt,
			Asset:       asset,
			Source:      release,
		}

		if !found ||
			candidate.PublishedAt.After(latest.PublishedAt) ||
			(candidate.PublishedAt.Equal(latest.PublishedAt) && candidate.TagName > latest.TagName) {
			latest = candidate
			found = true
		}
	}

	return latest, found
}

// selectLatestStableRelease picks the highest semantic version among the
// published, non-prerelease releases that carry the asset for this platform.
func selectLatestStableRelease(releases []githubRelease, assetName string) (snapshotReleaseCandidate, bool) {
	var latest snapshotReleaseCandidate
	var latestVersion semver.Version
	found := false

	for _, release := range releases {
		if release.Draft || release.Prerelease {
			continue
		}

		asset, ok := findReleaseAsset(release, assetName)
		if !ok {
			continue
		}

		version, err := parseVersion(release.TagName)
		if err != nil {
			continue
		}

		candidate := snapshotReleaseCandidate{
			TagName:     release.TagName,
			Name:        release.Name,
			Body:        release.Body,
			HTMLURL:     release.HTMLURL,
			PublishedAt: release.PublishedAt,
			Asset:       asset,
			Source:      release,
		}

		if !found ||
			version.GT(latestVersion) ||
			(version.EQ(latestVersion) && candidate.TagName > latest.TagName) {
			latest = candidate
			latestVersion = version
			found = true
		}
	}

	return latest, found
}

func snapshotNeedsUpdate(currentVersion string, latest snapshotReleaseCandidate) bool {
	return currentVersion != latest.TagName
}

func isContainerAgent() bool {
	_, err := os.Stat(containerMarkerPath)
	return err == nil
}

func splitRepoSlug(slug string) (string, string, error) {
	parts := strings.Split(slug, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("invalid repo slug %q, expected owner/name", slug)
	}
	return parts[0], parts[1], nil
}

func listGitHubReleases(owner, repo string) ([]githubRelease, error) {
	var releases []githubRelease

	for page := 1; ; page++ {
		endpoint := fmt.Sprintf(
			"%s/repos/%s/%s/releases?per_page=100&page=%d",
			githubAPIBaseURL,
			url.PathEscape(owner),
			url.PathEscape(repo),
			page,
		)
		req, err := http.NewRequest(http.MethodGet, endpoint, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create GitHub releases request: %w", err)
		}

		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("User-Agent", "komari-agent")
		if token := os.Getenv("GITHUB_TOKEN"); token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, fmt.Errorf("failed to list GitHub releases: %w", err)
		}

		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
			return nil, fmt.Errorf("GitHub releases API returned status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}

		var pageReleases []githubRelease
		if err := json.NewDecoder(resp.Body).Decode(&pageReleases); err != nil {
			_ = resp.Body.Close()
			return nil, fmt.Errorf("failed to decode GitHub releases response: %w", err)
		}
		_ = resp.Body.Close()

		releases = append(releases, pageReleases...)
		if len(pageReleases) < 100 {
			return releases, nil
		}
	}
}

func currentExecutablePath() (string, error) {
	cmdPath, err := os.Executable()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "windows" && !strings.HasSuffix(cmdPath, ".exe") {
		cmdPath += ".exe"
	}

	stat, err := os.Lstat(cmdPath)
	if err != nil {
		return "", fmt.Errorf("failed to stat %q: %w", cmdPath, err)
	}
	if stat.Mode()&os.ModeSymlink != 0 {
		resolved, err := filepath.EvalSymlinks(cmdPath)
		if err != nil {
			return "", fmt.Errorf("failed to resolve symlink %q for executable: %w", cmdPath, err)
		}
		cmdPath = resolved
	}

	return cmdPath, nil
}

// applyVerifiedUpdate downloads a release asset, verifies it against the
// checksum published in the same release and only then replaces cmdPath.
//
// It fails closed: any missing, malformed or mismatched checksum aborts the
// update and leaves the running binary untouched.
func applyVerifiedUpdate(cmdPath string, release githubRelease, asset githubReleaseAsset) error {
	expected, source, err := resolveExpectedChecksum(http.DefaultClient, release, asset.Name)
	if err != nil {
		return err
	}

	tmpPath, err := verifiedDownload(http.DefaultClient, asset.BrowserDownloadURL, expected, asset.Size, filepath.Dir(cmdPath))
	if err != nil {
		return err
	}
	defer os.Remove(tmpPath)

	sum, err := hex.DecodeString(expected)
	if err != nil {
		return checksumErrorf("invalid checksum %q from %s", expected, source)
	}

	file, err := os.Open(tmpPath)
	if err != nil {
		return fmt.Errorf("failed to open verified download: %w", err)
	}
	defer file.Close()

	log.Printf("Verified %s against %s (%s)", asset.Name, source, expected)
	if err := goUpdate.Apply(file, goUpdate.Options{TargetPath: cmdPath, Checksum: sum}); err != nil {
		if rollbackErr := goUpdate.RollbackError(err); rollbackErr != nil {
			log.Printf("[ERROR] failed to roll back %s: %v", cmdPath, rollbackErr)
		}
		return fmt.Errorf("failed to replace %s: %w", cmdPath, err)
	}
	return nil
}

func DoUpdateWorks() {
	ticker_ := time.NewTicker(time.Duration(6) * time.Hour)
	for range ticker_.C {
		CheckAndUpdate()
	}
}

func checkAndUpdateStable(currentSemVer semver.Version) error {
	if isContainerAgent() {
		log.Println("Agent is running in a container; skip binary self-update. Refresh the container image instead.")
		return nil
	}

	owner, repo, err := splitRepoSlug(Repo)
	if err != nil {
		return err
	}

	releases, err := listGitHubReleases(owner, repo)
	if err != nil {
		return err
	}

	assetName := expectedAssetName(runtime.GOOS, runtime.GOARCH)
	latest, found := selectLatestStableRelease(releases, assetName)
	if !found {
		log.Printf("No suitable release asset was found for %s. Current version is considered up-to-date.", assetName)
		return nil
	}

	latestVersion, err := parseVersion(latest.TagName)
	if err != nil {
		return fmt.Errorf("failed to parse release tag %q: %w", latest.TagName, err)
	}
	if !needUpdate(currentSemVer, latestVersion) {
		log.Println("Current version is the latest:", CurrentVersion)
		return nil
	}

	cmdPath, err := currentExecutablePath()
	if err != nil {
		return fmt.Errorf("failed to resolve current executable path: %w", err)
	}

	log.Printf("Will update %s from %s to %s\n", cmdPath, CurrentVersion, latest.TagName)
	if err := applyVerifiedUpdate(cmdPath, latest.Source, latest.Asset); err != nil {
		return fmt.Errorf("failed to update to %s: %w", latest.TagName, err)
	}

	// Default is installed as a service, so don't automatically restart
	log.Printf("Successfully updated to version %s\n", latest.TagName)
	os.Exit(42)
	return nil
}

func checkAndUpdateSnapshot() error {
	if isContainerAgent() {
		log.Println("Snapshot agent is running in a container; skip binary self-update. Refresh the ghcr.io image tagged 'snapshot' instead.")
		return nil
	}

	owner, repo, err := splitRepoSlug(Repo)
	if err != nil {
		return err
	}

	releases, err := listGitHubReleases(owner, repo)
	if err != nil {
		return err
	}

	assetName := expectedAssetName(runtime.GOOS, runtime.GOARCH)
	latest, found := selectLatestSnapshotRelease(releases, assetName)
	if !found {
		log.Printf("No suitable snapshot release asset was found for %s. Current snapshot is considered up-to-date.", assetName)
		return nil
	}

	if !snapshotNeedsUpdate(CurrentVersion, latest) {
		log.Println("Current snapshot version is the latest:", CurrentVersion)
		return nil
	}

	cmdPath, err := currentExecutablePath()
	if err != nil {
		return fmt.Errorf("failed to resolve current executable path: %w", err)
	}

	log.Printf("Will update %s from snapshot %s to %s\n", cmdPath, CurrentVersion, latest.TagName)
	if err := applyVerifiedUpdate(cmdPath, latest.Source, latest.Asset); err != nil {
		return fmt.Errorf("failed to update to snapshot %s: %w", latest.TagName, err)
	}

	log.Printf("Successfully updated to snapshot version %s\n", latest.TagName)
	os.Exit(42)
	return nil
}

// 检查更新并执行自动更新
func CheckAndUpdate() error {
	log.Println("Checking update...")

	http.DefaultClient = dnsresolver.GetHTTPClient(60 * time.Second)

	if detectBuildTrack(CurrentVersion) == snapshotTrack {
		return checkAndUpdateSnapshot()
	}

	currentSemVer, err := parseVersion(CurrentVersion)
	if err != nil {
		return fmt.Errorf("failed to parse current version: %v", err)
	}

	return checkAndUpdateStable(currentSemVer)
}
