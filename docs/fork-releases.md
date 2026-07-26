# Fork releases and container images

This fork tracks `makeplane/plane` and carries backported patches on top. It
publishes its own container images so those patches can actually be deployed.

## Where the images live

`ghcr.io/crewlet/plane-<component>`, for the six components upstream ships:

| Image | Built from |
| --- | --- |
| `plane-frontend` | `apps/web/Dockerfile.web` |
| `plane-space` | `apps/space/Dockerfile.space` |
| `plane-admin` | `apps/admin/Dockerfile.admin` |
| `plane-live` | `apps/live/Dockerfile.live` |
| `plane-backend` | `apps/api/Dockerfile.api` |
| `plane-proxy` | `apps/proxy/Dockerfile.ce` |

Upstream's `build-branch.yml` is left untouched but is inert here: it pushes to
makeplane's Docker Hub account and builds on makeplane's private Docker Build
Cloud endpoint. `ghcr-build.yml` replaces it for this fork and needs no secrets
— GHCR authenticates with the `GITHUB_TOKEN` that Actions provides.

> The first successful run creates the packages as **private**. Make them public
> (or grant pull access) in the org's Packages settings if unauthenticated hosts
> need to pull them.

## Tags

| Trigger | Image tags |
| --- | --- |
| Push to `preview` | `preview`, `preview-<short sha>` |
| Push of tag `vX.Y.Z` | `vX.Y.Z`, plus `latest` when there is no pre-release suffix |
| Manual run | whatever `image_tag` is set to |

`preview` is a rolling tag that moves with the branch. `preview-<sha>` is
immutable, so a deployment can pin one exact build.

## Cutting a release against an upstream release

`preview` gives a rolling build, but a deployment usually wants to sit on a
known upstream release with our patches applied. The
**Backport onto upstream release** workflow does that:

1. Fetches the upstream tag (e.g. `v0.29.1`).
2. Replays this fork's commits on top of it.
3. Tags the fork with the *same* version.
4. Builds and publishes images under that tag.

So `ghcr.io/crewlet/plane-backend:v0.29.1` means "upstream v0.29.1 plus our
backports", and `APP_RELEASE=v0.29.1` against this registry gets you exactly
that.

### How the patch set is found

This fork's `preview` is upstream's `preview` plus commits. The merge base of
the two is the upstream commit we forked from; everything after it is ours.
`git rebase` compares patch-ids while replaying, so any patch upstream has
merged in the meantime is dropped rather than applied twice — which is what
makes this safe to re-run as the backported PRs land upstream.

### When it will conflict

Our patches are written against the fork point. Replaying them onto a release
cut **before** that point re-targets them at older code, and that is where
conflicts come from. The workflow warns upfront when the requested tag predates
the fork point, and fails with the conflicting file list rather than pushing a
broken tag.

This is not hypothetical: replaying the current 49 commits onto `v1.3.1` — two
months and 50 upstream commits behind our base — conflicts in four files around
`webhook_task.py` / `url_security.py`. Releases cut at or after the fork point
are the intended input; older ones need a manual pass:

```bash
git fetch --no-tags upstream 'refs/tags/vX.Y.Z:refs/upstream/tags/vX.Y.Z'
base=$(git merge-base upstream/preview origin/preview)
git checkout -B backport/vX.Y.Z origin/preview
git rebase --onto refs/upstream/tags/vX.Y.Z "$base"
# resolve, then push the branch and tag it
```

Keeping the fork's `preview` reasonably current with upstream's `preview` keeps
this cheap.

## Running the images

`deployments/cli/community/docker-compose.yml` takes the registry from
`PLANE_IMAGE_PREFIX`, defaulting to `makeplane` so upstream behaviour is
unchanged. To run this fork's builds:

```bash
PLANE_IMAGE_PREFIX=ghcr.io/crewlet
APP_RELEASE=preview      # or an upstream release tag, e.g. v0.29.1
```

Both are set in `deployments/cli/community/variables.env`.

## Architectures

Builds are `linux/amd64` by default. Both workflows take an `arm64` input that
adds `linux/arm64`; it is off by default because GitHub's runners emulate it
under QEMU, which makes the build dramatically slower. Upstream sidesteps this
with a Docker Build Cloud endpoint that this fork has no access to.
