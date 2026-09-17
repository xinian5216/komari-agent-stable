package update

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestParsePerAssetChecksum(t *testing.T) {
	const asset = "komari-agent-linux-amd64"
	const digest = "6605b5d97f8816f873759e8446670631097cbf2b89ff57b94061ae99537221ba"

	cases := []struct {
		name    string
		content string
		wantErr bool
	}{
		{"bare digest", digest + "\n", false},
		{"digest with name", digest + "  " + asset + "\n", false},
		{"binary mode name", digest + " *" + asset + "\n", false},
		{"crlf", digest + "\r\n", false},
		{"uppercase digest", strings.ToUpper(digest) + "\n", false},
		{"empty", "", true},
		{"two lines", digest + "\n" + digest + "\n", true},
		{"short digest", "abc123\n", true},
		{"not hex", strings.Repeat("z", 64) + "\n", true},
		{"other file", digest + "  other-binary\n", true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parsePerAssetChecksum([]byte(tc.content), asset)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error for %q", tc.content)
				}
				var checksumErr *ChecksumError
				if !errors.As(err, &checksumErr) {
					t.Fatalf("error %v is not a ChecksumError", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != digest {
				t.Fatalf("digest = %q, want %q", got, digest)
			}
		})
	}
}

func TestParseChecksumManifest(t *testing.T) {
	const asset = "komari-agent-linux-amd64"
	const digest = "6605b5d97f8816f873759e8446670631097cbf2b89ff57b94061ae99537221ba"
	const other = "ca5e1bc24bbb4a28844484b40bc5976654d811ec2cec71fe4615f77b1d4760ee"

	manifest := strings.Join([]string{
		digest + "  " + asset,
		other + "  komari-agent-linux-arm64",
		other + " *komari-agent-windows-amd64.exe",
	}, "\n") + "\n"

	got, err := parseChecksumManifest([]byte(manifest), asset)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != digest {
		t.Fatalf("digest = %q, want %q", got, digest)
	}

	if got, err := parseChecksumManifest([]byte(manifest), "komari-agent-windows-amd64.exe"); err != nil || got != other {
		t.Fatalf("binary-mode entry = (%q, %v)", got, err)
	}

	failures := map[string]string{
		"missing entry":      digest + "  something-else\n",
		"empty":              "",
		"malformed line":     "not-a-checksum  " + asset + "\n",
		"no file name":       digest + "\n",
		"conflicting digest": digest + "  " + asset + "\n" + other + "  " + asset + "\n",
	}
	for name, content := range failures {
		t.Run(name, func(t *testing.T) {
			if _, err := parseChecksumManifest([]byte(content), asset); err == nil {
				t.Fatalf("expected an error for %q", content)
			}
		})
	}
}

func TestSelectChecksumAssetsPrefersExactPerAssetName(t *testing.T) {
	const asset = "komari-agent-linux-amd64"
	release := githubRelease{
		TagName: "v1.5.10-stable.0",
		Assets: []githubReleaseAsset{
			{Name: "komari-agent-linux-arm64.sha256"},
			{Name: "SHA256SUMS"},
			{Name: asset + ".sha256"},
		},
	}

	assets := selectChecksumAssets(release, asset)
	if len(assets) != 2 {
		t.Fatalf("selectChecksumAssets returned %d assets, want 2", len(assets))
	}
	if assets[0].Name != asset+".sha256" || assets[1].Name != checksumManifestName {
		t.Fatalf("unexpected order: %q, %q", assets[0].Name, assets[1].Name)
	}
}

func TestResolveExpectedChecksumFailsClosedWhenReleaseHasNoChecksum(t *testing.T) {
	release := githubRelease{
		TagName: "v9.9.9-stable.0",
		Assets:  []githubReleaseAsset{{Name: "komari-agent-linux-amd64"}},
	}
	if _, _, err := resolveExpectedChecksum(nil, release, "komari-agent-linux-amd64"); err == nil {
		t.Fatal("expected an error when the release publishes no checksum")
	}
}

func TestVerifiedDownload(t *testing.T) {
	content := []byte("new agent binary")
	sum := sha256.Sum256(content)
	digest := hex.EncodeToString(sum[:])

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(content)
	}))
	defer server.Close()

	dir := t.TempDir()
	path, err := verifiedDownload(server.Client(), server.URL, digest, len(content), dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer os.Remove(path)
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(content) {
		t.Fatalf("downloaded content = %q", got)
	}

	t.Run("hash mismatch", func(t *testing.T) {
		wrong := strings.Repeat("0", 64)
		if _, err := verifiedDownload(server.Client(), server.URL, wrong, len(content), dir); err == nil {
			t.Fatal("expected a checksum error")
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		if len(entries) != 1 {
			t.Fatalf("temporary files were left behind: %v", entries)
		}
	})

	t.Run("size mismatch", func(t *testing.T) {
		if _, err := verifiedDownload(server.Client(), server.URL, digest, len(content)+1, dir); err == nil {
			t.Fatal("expected a size error")
		}
	})

	t.Run("http error", func(t *testing.T) {
		failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusNotFound)
		}))
		defer failing.Close()
		if _, err := verifiedDownload(failing.Client(), failing.URL, digest, 0, dir); err == nil {
			t.Fatal("expected an error for a non-200 response")
		}
	})
}

func checksumServer(t *testing.T, binary []byte, checksumBody string, includeChecksum bool, size int) (githubRelease, githubReleaseAsset) {
	t.Helper()

	assetName := expectedAssetName(runtime.GOOS, runtime.GOARCH)

	mux := http.NewServeMux()
	mux.HandleFunc("/binary", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(binary)
	})
	mux.HandleFunc("/binary.sha256", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(checksumBody))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	assets := []githubReleaseAsset{{ID: 1, Name: assetName, Size: size, BrowserDownloadURL: server.URL + "/binary"}}
	if includeChecksum {
		assets = append(assets, githubReleaseAsset{ID: 2, Name: assetName + ".sha256", Size: 65, BrowserDownloadURL: server.URL + "/binary.sha256"})
	}
	return githubRelease{TagName: "v9.9.9-stable.0", Assets: assets}, assets[0]
}

func TestApplyVerifiedUpdateReplacesTarget(t *testing.T) {
	binary := []byte("verified agent binary\n")
	sum := sha256.Sum256(binary)

	release, asset := checksumServer(t, binary, hex.EncodeToString(sum[:])+"\n", true, len(binary))

	target := filepath.Join(t.TempDir(), "agent")
	if err := os.WriteFile(target, []byte("old agent binary\n"), 0755); err != nil {
		t.Fatal(err)
	}

	if err := applyVerifiedUpdate(target, release, asset); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(binary) {
		t.Fatalf("target was not replaced: %q", got)
	}
}

func TestApplyVerifiedUpdateKeepsTargetOnChecksumMismatch(t *testing.T) {
	binary := []byte("tampered agent binary\n")
	original := []byte("old agent binary\n")

	release, asset := checksumServer(t, binary, strings.Repeat("0", 64)+"\n", true, len(binary))

	target := filepath.Join(t.TempDir(), "agent")
	if err := os.WriteFile(target, original, 0755); err != nil {
		t.Fatal(err)
	}

	err := applyVerifiedUpdate(target, release, asset)
	if err == nil {
		t.Fatal("expected a checksum failure")
	}
	var checksumErr *ChecksumError
	if !errors.As(err, &checksumErr) {
		t.Fatalf("error %v is not a ChecksumError", err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(original) {
		t.Fatalf("target was modified despite the checksum failure: %q", got)
	}
}

func TestApplyVerifiedUpdateKeepsTargetWhenChecksumMissing(t *testing.T) {
	binary := []byte("agent binary without checksum\n")
	original := []byte("old agent binary\n")

	release, asset := checksumServer(t, binary, "", false, len(binary))

	target := filepath.Join(t.TempDir(), "agent")
	if err := os.WriteFile(target, original, 0755); err != nil {
		t.Fatal(err)
	}

	err := applyVerifiedUpdate(target, release, asset)
	if err == nil {
		t.Fatal("expected a checksum failure when the release publishes no checksum")
	}
	var checksumErr *ChecksumError
	if !errors.As(err, &checksumErr) {
		t.Fatalf("error %v is not a ChecksumError", err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(original) {
		t.Fatalf("target was modified despite the missing checksum: %q", got)
	}
}

func TestCheckAndUpdateStableAbortsOnChecksumMismatch(t *testing.T) {
	version, err := parseVersion("1.0.0")
	if err != nil {
		t.Fatal(err)
	}

	binary := []byte("tampered agent binary\n")
	release, asset := checksumServer(t, binary, strings.Repeat("0", 64)+"\n", true, len(binary))

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprintf(w, `[{"tag_name":%q,"assets":[{"id":1,"name":%q,"size":%d,"browser_download_url":%q},{"id":2,"name":%q,"size":65,"browser_download_url":%q}]}]`,
			release.TagName, asset.Name, len(binary), asset.BrowserDownloadURL, asset.Name+".sha256", asset.BrowserDownloadURL+".sha256")
	}))
	defer server.Close()

	originalBase := githubAPIBaseURL
	githubAPIBaseURL = server.URL
	t.Cleanup(func() { githubAPIBaseURL = originalBase })

	originalVersion := CurrentVersion
	CurrentVersion = "1.0.0"
	t.Cleanup(func() { CurrentVersion = originalVersion })

	if err := checkAndUpdateStable(version); err == nil {
		t.Fatal("expected the update to fail closed on a checksum mismatch")
	}
}

func TestCheckAndUpdateSkipsInContainer(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "marker")
	if err := os.WriteFile(marker, nil, 0644); err != nil {
		t.Fatal(err)
	}
	originalMarker := containerMarkerPath
	containerMarkerPath = marker
	t.Cleanup(func() { containerMarkerPath = originalMarker })

	originalBase := githubAPIBaseURL
	githubAPIBaseURL = "http://127.0.0.1:1"
	t.Cleanup(func() { githubAPIBaseURL = originalBase })

	version, err := parseVersion("1.0.0")
	if err != nil {
		t.Fatal(err)
	}
	if err := checkAndUpdateStable(version); err != nil {
		t.Fatalf("container agents must skip self-update without touching the network: %v", err)
	}

	originalVersion := CurrentVersion
	CurrentVersion = "Snapshot-2609150215"
	t.Cleanup(func() { CurrentVersion = originalVersion })
	if err := checkAndUpdateSnapshot(); err != nil {
		t.Fatalf("container snapshot agents must skip self-update without touching the network: %v", err)
	}
}

func TestSelectLatestStableRelease(t *testing.T) {
	const assetName = "komari-agent-linux-amd64"
	asset := githubReleaseAsset{Name: assetName, BrowserDownloadURL: "https://example.invalid/binary"}

	releases := []githubRelease{
		{TagName: "v1.5.9", Assets: []githubReleaseAsset{asset}},
		{TagName: "v1.5.10-stable.0", Assets: []githubReleaseAsset{asset}},
		{TagName: "v1.5.10-stable.1", Assets: []githubReleaseAsset{asset}},
		{TagName: "v1.6.0", Draft: true, Assets: []githubReleaseAsset{asset}},
		{TagName: "Snapshot-2609150215", Prerelease: true, Assets: []githubReleaseAsset{asset}},
		{TagName: "v2.0.0", Assets: []githubReleaseAsset{{Name: "komari-agent-plan9-sparc"}}},
	}

	latest, found := selectLatestStableRelease(releases, assetName)
	if !found {
		t.Fatal("no stable release was selected")
	}
	if latest.TagName != "v1.5.10-stable.1" {
		t.Fatalf("selected %q, want the highest published semver", latest.TagName)
	}

	if _, found := selectLatestStableRelease(nil, assetName); found {
		t.Fatal("selected a release from an empty list")
	}
}

// TestPublishedReleaseChecksumsAreUsable checks the checksum resolver against
// the real release that is already published. It is skipped by default so the
// test suite stays offline; run it with KOMARI_AGENT_NETWORK_TEST=1.
func TestPublishedReleaseChecksumsAreUsable(t *testing.T) {
	if os.Getenv("KOMARI_AGENT_NETWORK_TEST") != "1" {
		t.Skip("set KOMARI_AGENT_NETWORK_TEST=1 to verify the published release assets")
	}

	releases, err := listGitHubReleases("xinian5216", "komari-agent-stable")
	if err != nil {
		t.Fatalf("could not list releases: %v", err)
	}

	var published githubRelease
	for _, release := range releases {
		if release.TagName == "v1.5.10-stable.0" {
			published = release
			break
		}
	}
	if published.TagName == "" {
		t.Fatal("release v1.5.10-stable.0 was not found")
	}

	for _, assetName := range []string{"komari-agent-linux-amd64", "komari-agent-windows-amd64.exe"} {
		digest, source, err := resolveExpectedChecksum(http.DefaultClient, published, assetName)
		if err != nil {
			t.Fatalf("%s: %v", assetName, err)
		}
		if len(digest) != 64 {
			t.Fatalf("%s: unexpected digest %q", assetName, digest)
		}
		t.Logf("%s -> %s (%s)", assetName, digest, source)
	}

	// The manifest resolution must agree with the per-asset file.
	perAsset, _, err := resolveExpectedChecksum(http.DefaultClient, githubRelease{
		TagName: published.TagName,
		Assets:  selectChecksumAssets(published, "komari-agent-linux-amd64")[:1],
	}, "komari-agent-linux-amd64")
	if err != nil {
		t.Fatalf("per-asset checksum: %v", err)
	}
	if perAsset == "" {
		t.Fatal("empty per-asset checksum")
	}
}
