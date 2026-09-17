package update

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
)

const (
	// perAssetChecksumSuffix is the suffix of the per-asset checksum file
	// published by this fork's release pipeline, e.g.
	// komari-agent-linux-amd64.sha256.
	perAssetChecksumSuffix = ".sha256"
	// checksumManifestName is the combined manifest published next to the
	// per-asset files.
	checksumManifestName = "SHA256SUMS"
	// maxChecksumAssetBytes bounds how much of a checksum asset is read.
	maxChecksumAssetBytes = 1 << 20
)

var hexDigestPattern = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

// ChecksumError reports a checksum that could not be obtained or verified. The
// caller must treat it as a hard failure: the running binary is never replaced
// when the checksum is missing, malformed or does not match.
type ChecksumError struct {
	Reason string
}

func (e *ChecksumError) Error() string {
	return "checksum verification failed: " + e.Reason
}

func checksumErrorf(format string, args ...interface{}) error {
	return &ChecksumError{Reason: fmt.Sprintf(format, args...)}
}

// selectChecksumAssets returns the checksum assets to try for assetName, in
// priority order. Assets are matched by their exact name, never by position.
func selectChecksumAssets(release githubRelease, assetName string) []githubReleaseAsset {
	var assets []githubReleaseAsset
	if asset, ok := findReleaseAsset(release, assetName+perAssetChecksumSuffix); ok {
		assets = append(assets, asset)
	}
	if asset, ok := findReleaseAsset(release, checksumManifestName); ok {
		assets = append(assets, asset)
	}
	return assets
}

// parsePerAssetChecksum parses the content of a `<name>.sha256` file: exactly
// one line holding the hex digest, optionally followed by the file name.
func parsePerAssetChecksum(content []byte, assetName string) (string, error) {
	lines := nonEmptyLines(content)
	if len(lines) != 1 {
		return "", checksumErrorf("%s must contain exactly one checksum line, got %d", assetName+perAssetChecksumSuffix, len(lines))
	}
	digest, name, err := splitChecksumLine(lines[0])
	if err != nil {
		return "", err
	}
	if name != "" && name != assetName {
		return "", checksumErrorf("%s names %q instead of %q", assetName+perAssetChecksumSuffix, name, assetName)
	}
	return digest, nil
}

// parseChecksumManifest parses SHA256SUMS content and returns the digest listed
// for assetName. Conflicting duplicate entries and malformed lines are refused.
func parseChecksumManifest(content []byte, assetName string) (string, error) {
	lines := nonEmptyLines(content)
	if len(lines) == 0 {
		return "", checksumErrorf("%s is empty", checksumManifestName)
	}
	found := ""
	for _, line := range lines {
		digest, name, err := splitChecksumLine(line)
		if err != nil {
			return "", err
		}
		if name == "" {
			return "", checksumErrorf("%s line %q has no file name", checksumManifestName, line)
		}
		if name != assetName {
			continue
		}
		if found != "" && found != digest {
			return "", checksumErrorf("%s lists conflicting checksums for %s", checksumManifestName, assetName)
		}
		found = digest
	}
	if found == "" {
		return "", checksumErrorf("%s has no entry for %s", checksumManifestName, assetName)
	}
	return found, nil
}

func nonEmptyLines(content []byte) []string {
	var lines []string
	for _, line := range strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			lines = append(lines, trimmed)
		}
	}
	return lines
}

// splitChecksumLine accepts "hex", "hex  name" and the binary-mode "hex *name"
// form produced by sha256sum.
func splitChecksumLine(line string) (digest string, name string, err error) {
	fields := strings.Fields(line)
	if len(fields) == 0 || len(fields) > 2 {
		return "", "", checksumErrorf("malformed checksum line %q", line)
	}
	digest = strings.ToLower(fields[0])
	if !hexDigestPattern.MatchString(digest) {
		return "", "", checksumErrorf("malformed checksum %q", fields[0])
	}
	if len(fields) == 2 {
		name = strings.TrimPrefix(fields[1], "*")
	}
	return digest, name, nil
}

// fetchChecksum downloads a checksum asset and returns the digest it declares
// for assetName.
func fetchChecksum(client *http.Client, asset githubReleaseAsset, assetName string) (string, error) {
	body, err := downloadAsset(client, asset.BrowserDownloadURL)
	if err != nil {
		return "", err
	}
	defer body.Close()

	content, err := io.ReadAll(io.LimitReader(body, maxChecksumAssetBytes))
	if err != nil {
		return "", checksumErrorf("could not read %s: %v", asset.Name, err)
	}
	if asset.Name == checksumManifestName {
		return parseChecksumManifest(content, assetName)
	}
	return parsePerAssetChecksum(content, assetName)
}

// resolveExpectedChecksum returns the expected hex digest for assetName and the
// name of the asset it came from. Failing to obtain a usable checksum is an
// error: the update must fail closed instead of continuing unverified.
func resolveExpectedChecksum(client *http.Client, release githubRelease, assetName string) (string, string, error) {
	assets := selectChecksumAssets(release, assetName)
	if len(assets) == 0 {
		return "", "", checksumErrorf("release %s provides neither %s nor %s", release.TagName, assetName+perAssetChecksumSuffix, checksumManifestName)
	}
	var lastErr error
	for _, asset := range assets {
		digest, err := fetchChecksum(client, asset, assetName)
		if err == nil {
			return digest, asset.Name, nil
		}
		lastErr = err
	}
	return "", "", lastErr
}

// verifiedDownload streams assetURL into a temporary file and returns its path
// only when the SHA256 matches expectedDigest and, when known, the declared
// asset size. Any mismatch removes the temporary file and fails.
func verifiedDownload(client *http.Client, assetURL, expectedDigest string, expectedSize int, dir string) (string, error) {
	body, err := downloadAsset(client, assetURL)
	if err != nil {
		return "", err
	}
	defer body.Close()

	tmp, err := os.CreateTemp(dir, ".komari-agent-download-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temporary download file: %w", err)
	}
	tmpPath := tmp.Name()
	discard := func(err error) (string, error) {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return "", err
	}

	hasher := sha256.New()
	written, err := io.Copy(io.MultiWriter(tmp, hasher), body)
	if err != nil {
		return discard(fmt.Errorf("failed to download %s: %w", assetURL, err))
	}
	if err := tmp.Sync(); err != nil {
		return discard(fmt.Errorf("failed to flush download: %w", err))
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("failed to close download: %w", err)
	}

	actual := hex.EncodeToString(hasher.Sum(nil))
	if actual != expectedDigest {
		_ = os.Remove(tmpPath)
		return "", checksumErrorf("downloaded file does not match %s: expected %s, got %s", assetURL, expectedDigest, actual)
	}
	if expectedSize > 0 && written != int64(expectedSize) {
		_ = os.Remove(tmpPath)
		return "", checksumErrorf("downloaded file has unexpected size: expected %d bytes, got %d", expectedSize, written)
	}
	return tmpPath, nil
}

// downloadAsset opens a release asset over HTTP.
func downloadAsset(client *http.Client, assetURL string) (io.ReadCloser, error) {
	req, err := http.NewRequest(http.MethodGet, assetURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "komari-agent")
	if token := os.Getenv("GITHUB_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		return nil, fmt.Errorf("failed to download %s: unexpected status %d", assetURL, resp.StatusCode)
	}
	return resp.Body, nil
}
