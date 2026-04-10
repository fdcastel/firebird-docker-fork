## How ARM64 builds work

### 1. Build phase — on each arch runner independently

The `Build` task runs on **both** the `ubuntu-latest` (amd64) and the `ubuntu-24.04-arm` (arm64) GitHub Actions runners in parallel via a matrix job.

On each runner, `Build` detects the host architecture at runtime:

```powershell
$hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }
```

It then calls `docker build` and tags the produced image with an arch suffix:

- **amd64 runner** → `firebirdsql/firebird-amd64:<tag>` (e.g. `firebirdsql/firebird-amd64:5.0.3-bookworm`)
- **arm64 runner** → `firebirdsql/firebird-arm64:<tag>` (e.g. `firebirdsql/firebird-arm64:5.0.3-bookworm`)

For Firebird 3.x and 4.x, which have no upstream ARM64 binary, `Build` checks `assets.json` for an `arm64` key. If it is absent, the arm64 build is skipped on the arm64 runner. The `Test` task similarly skips those versions on arm64.

### 2. Publish-Arch — push staging tags (runs on each arch runner)

After the build and tests, `Publish-Arch` pushes the locally built images to the registry using **tag-based staging** (not a separate image name):

```powershell
docker tag  "$imagePrefix/firebird-${hostArch}:$tag"  "$imagePrefix/firebird:$tag-$hostArch"
docker push "$imagePrefix/firebird:$tag-$hostArch"
```

So for tag `5.0.3-bookworm` this produces two pushed tags inside the **same** registry package:
- `firebirdsql/firebird:5.0.3-bookworm-amd64`
- `firebirdsql/firebird:5.0.3-bookworm-arm64`

Both runners run `Publish-Arch` in parallel. When the matrix job is done, both arch-specific staging tags are in the registry.

### 3. Publish-Manifests — create OCI multi-arch manifests (runs once, on ubuntu-latest)

The `create-manifests` job in `publish.yaml` runs after all `build-and-test` matrix jobs succeed (`needs: build-and-test`). It calls `Publish-Manifests`:

```powershell
docker manifest create --amend "$imagePrefix/firebird:$tag" \
    "$imagePrefix/firebird:$tag-amd64" \
    "$imagePrefix/firebird:$tag-arm64"

docker manifest annotate "$imagePrefix/firebird:$tag" \
    "$imagePrefix/firebird:$tag-amd64" --os linux --arch amd64
docker manifest annotate "$imagePrefix/firebird:$tag" \
    "$imagePrefix/firebird:$tag-arm64" --os linux --arch arm64

docker manifest push "$imagePrefix/firebird:$tag"
```

This assembles the staging tags into a single OCI manifest list (multi-arch image). After the push, `docker pull firebirdsql/firebird:5.0.3-bookworm` on any machine automatically pulls the correct architecture.

For **amd64-only** versions (Firebird 3.x, 4.x), `Publish-Manifests` creates a single-arch manifest from the `-amd64` staging tag instead.

---

## Summary diagram

```
ubuntu-latest (amd64)                 ubuntu-24.04-arm (arm64)
─────────────────────                 ─────────────────────────
Build                                 Build
  → firebird-amd64:<tag>                → firebird-arm64:<tag>
Test                                  Test (skips FB3/FB4)
Publish-Arch                          Publish-Arch
  → push firebird:<tag>-amd64           → push firebird:<tag>-arm64
                  ↘                       ↙
               create-manifests (ubuntu-latest)
               Publish-Manifests
                 docker manifest create firebird:<tag>
                   ← firebird:<tag>-amd64
                   ← firebird:<tag>-arm64
                 docker manifest push firebird:<tag>
```

