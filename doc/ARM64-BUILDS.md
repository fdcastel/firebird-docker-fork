## How ARM64 builds work

### 1. Build phase — on each arch runner independently

The `Build` task runs on **both** the `ubuntu-latest` (amd64) and the `ubuntu-24.04-arm` (arm64) GitHub Actions runners in parallel via a matrix job.

On each runner, `Build` detects the host architecture at runtime:

```powershell
$hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }
```

It then calls `docker buildx build --load` and tags the produced image with an arch suffix:

- **amd64 runner** → `firebirdsql/firebird-amd64:<tag>` (e.g. `firebirdsql/firebird-amd64:5.0.3-bookworm`)
- **arm64 runner** → `firebirdsql/firebird-arm64:<tag>` (e.g. `firebirdsql/firebird-arm64:5.0.3-bookworm`)

These are local-only tags in the runner's Docker daemon, used for testing. They are **never pushed** to any registry.

For Firebird 3.x and 4.x, which have no upstream ARM64 binary, `Build` checks `assets.json` for an `arm64` key. If it is absent, the arm64 build is skipped on the arm64 runner. The `Test` task similarly skips those versions on arm64.

### 2. Push-Digests — push by digest, no tags created (runs on each arch runner)

After the build and tests, `Push-Digests` pushes each image to the registry **by digest** — no tag is created. This uses `docker buildx build --push` with `push-by-digest=true`:

```powershell
docker buildx build --push `
    --output "type=image,name=$imagePrefix/firebird,push-by-digest=true,name-canonical=true,push=true" `
    --metadata-file $metadataFile `
    $distributionFolder
```

The digest (e.g. `sha256:abc123…`) is captured from the metadata file and saved to `generated/digests-{arch}.json`. This file is uploaded as a GitHub Actions artifact.

No staging tags, no staging repos — only raw image layers addressed by digest exist in the registry at this point.

### 3. Publish-Manifests — create OCI multi-arch manifests (runs once, on ubuntu-latest)

The `create-manifests` job in `publish.yaml` runs after all `build-and-test` matrix jobs succeed (`needs: build-and-test`). It downloads the digest artifacts from both runners, then calls `Publish-Manifests`:

```powershell
docker buildx imagetools create --tag "$imagePrefix/firebird:$tag" `
    "$imagePrefix/firebird@$amd64Digest" `
    "$imagePrefix/firebird@$arm64Digest"
```

This assembles the per-arch digests into a single OCI manifest list (multi-arch image). After this, `docker pull firebirdsql/firebird:5.0.3-bookworm` on any machine automatically pulls the correct architecture.

For **amd64-only** versions (Firebird 3.x, 4.x), `Publish-Manifests` creates a single-arch manifest from the amd64 digest only.

---

## Summary diagram

```
ubuntu-latest (amd64)                 ubuntu-24.04-arm (arm64)
─────────────────────                 ─────────────────────────
Build                                 Build
  → firebird-amd64:<tag> (local)        → firebird-arm64:<tag> (local)
Test                                  Test (skips FB3/FB4)
Push-Digests                          Push-Digests
  → push by digest (no tag)             → push by digest (no tag)
  → save sha256 to artifact             → save sha256 to artifact
                  ↘                       ↙
               create-manifests (ubuntu-latest)
               download digest artifacts
               Publish-Manifests
                 docker buildx imagetools create firebird:<tag>
                   ← firebird@sha256:<amd64>
                   ← firebird@sha256:<arm64>
                 → final multi-arch tag published
```

