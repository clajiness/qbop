# Image publishing

`docker.yml` handles normal branch/release triggers and pull-request build checks. `security-rebuild.yml` checks the current stable release's upstream Ruby image daily. Both publishing triggers call `publish-image.yml`, which checks out the maintained publisher from the default branch and the application at its exact source commit into separate directories.

The shared job builds one unique `staging-<run-id>-<attempt>` multiarch candidate, validates it, then calls `image_publisher.rb` to promote an immutable digest. That Ruby file has three commands: `check`, `prepare`, and `publish`. It is the only production tag writer. There is no recovery database, legacy Dockerfile adapter, or disposable publishing namespace.

## Rebuilds and tag policy

The monitor selects the highest numeric published `vX.Y.Z` GitHub Release, excluding drafts and prereleases. It reads that commit's Dockerfile and `.ruby-version`, then resolves the exact Ruby slim tag's multiarch digest. A build is needed when any current alias is missing, the four aliases disagree, or their recorded source/base identity differs from the current release and upstream digest. Unchanged, completely published images are skipped. **Actions → Upstream security rebuild → Run workflow → force** requests a fresh build even without a digest change; select the default branch.

Security builds pass `BASE_IMAGE=ruby:<released-version>-slim@sha256:…` to the released Dockerfile, use `pull` and `no-cache`, and run Debian package updates within that base distribution. `BUNDLE_FROZEN=true bundle install` preserves the released Gemfile and lockfile. Ruby, gems, and application source are never automatically updated. There is no separate weekly/monthly build or Debian-only update schedule; use force for OS updates between upstream image changes.

A pinned Ruby patch tag can eventually stop receiving upstream updates. A successful unchanged-digest check does not establish that the base still receives security fixes. Review Ruby/base support periodically and update the pinned version through a normal application release when needed. Force can refresh available Debian packages but does not upgrade Ruby or change the base distribution.

The release Dockerfile must already support the `BASE_IMAGE` argument, frozen installation, and Debian upgrades. An incompatible release fails with a request to publish a compatible normal release. **Initial rollout requires a normal application release containing the updated Dockerfile.** Merging the automation alone cannot retrofit the existing release. Publisher files must also be on the default branch before publishing runs can use them.

For current release `v3.6.0`, the mutable tags are `v3.6.0`, `v3.6`, `v3`, and `latest`. All reference the same validated multiarch digest. Security rebuilds never touch `sha-*`, branch tags such as `main`, or superseded exact release tags. Normal releases additionally create an absent `sha-<12-character-commit>` tag. Existing SHA tags never move. Branch builds update their normalized branch tag and create an absent SHA tag; release aliases, SHA tags, and `staging-*` are reserved against branch-name collisions.

Normal release reruns reuse the existing exact release image, preserving security refreshes. They can fill missing or inconsistent current aliases. Older release workflows are rejected entirely once a newer stable GitHub Release or a newer image in a relevant alias exists; historical release-line publishing is unsupported. Moved Git tags or conflicting exact-release source identities fail and require investigation.

## Validation and concurrency

Before promotion, the publisher checks both AMD64 and ARM64 manifests and source/base labels. Isolated containers verify the released Ruby version, actual CPU architecture, byte-for-byte Gemfile/lockfile contents, and application startup with local HTTP. Failed validation does not change production tags.

One `qbop-release-publish` Actions concurrency group covers the entire shared job, including building. This deliberately serializes builds as well as publication, avoiding competing candidates and extra orchestration. It does not cancel the running job and queues pending jobs with `queue: max`; see [GitHub concurrency behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency). Source refs, the current release, registry versions, and the security base digest are checked again before individual tag writes. Existing SHA tags are preserved, and final digest reads verify publication.

Historical workflow definitions predating this system and direct registry writes bypass its coordination. Maintainers must avoid running old direct-publishing workflows against production. The lock does not provide a registry-enforced permission boundary or an atomic transaction with GitHub release creation.

## Failure recovery and cleanup

GHCR updates tags individually. A failed or cancelled run can leave a mixture of validated old and new images. The publisher does not roll back tags or automatically recover a previous candidate. The Actions log and summary identify the attempted tag, digest, and failed command.

Inspect the failure, fix credentials/configuration if necessary, then rerun the failed shared publishing job or the whole workflow in Actions. The shared job builds again. Security retries can promote a new candidate across all four aliases; normal release retries preserve the existing exact release digest. Unchanged upstream state does not suppress a retry while aliases are missing or disagree. If the release or upstream digest has changed, start a fresh security workflow instead of retrying stale inputs. The daily check will also detect incomplete state. Manual force remains available.

Commands use ordinary CLI exit codes and Actions job timeouts. Registry/API errors fail the run; there is no custom backoff or process supervisor. Inspect and rerun transient failures. A cancelled or full-queue job may also need a manual rerun. Schedules can be delayed or disabled; periodically check that the daily workflow is running.

Staging cleanup is manual. Do not delete GHCR package versions merely because they have a staging tag: the same digest may also have production aliases, and multiarch indexes depend on platform manifests that can appear untagged. Leaving staging references is acceptable.

Mutable tags do not update running containers automatically. Pull the selected image and recreate the container, for example with `docker compose pull` followed by `docker compose up -d`. Pin `ghcr.io/clajiness/qbop@sha256:…` when an exact container build is required; users on superseded releases must upgrade for further maintenance.

## Production rollout

These are maintainer instructions, not steps already performed. Use Bash, an authenticated GitHub CLI (`gh`), Docker Buildx, and Ruby. For private package reads, authenticate Docker to GHCR. The shared workflow is named **Build and publish validated image**; its callers are **Docker** (`docker.yml`) and **Upstream security rebuild** (`security-rebuild.yml`). **CI** (`ci.yml`) supplies the application checks.

Steps marked **GHCR writes** can publish staging or production images. Merge also enables the daily schedule, so complete the compatible release promptly. Avoid unrelated pushes/releases while comparing the baseline and refreshed digests.

1. **Commit and push the feature branch — GHCR writes may be triggered.** Review the diff, then:

   ```bash
   git switch feature/automated-image-rebuilds
   git add .github Dockerfile README.md docs spec/automation
   git commit -m "Automate upstream image security rebuilds"
   git push -u origin feature/automated-image-rebuilds
   ```

   Before initial merge, the branch-push publishing job cannot load the new publisher from `main` and may fail. This does not prevent the separate credential-free PR build from running. After rollout, branch pushes publish branch/SHA images normally.

2. **Open a PR against `main`:**

   ```bash
   gh pr create --repo clajiness/qbop --base main --head feature/automated-image-rebuilds \
     --title "Automated image security rebuilds" \
     --body "Monitor the released Ruby base digest and publish validated image refreshes through one shared publisher."
   PUBLISH_PR="$(gh pr view feature/automated-image-rebuilds --repo clajiness/qbop --json number --jq .number)"
   ```

3. **Inspect the actual PR checks:**

   ```bash
   gh pr checks "$PUBLISH_PR" --repo clajiness/qbop --watch
   ```

   Require successful `CI` security, lint, and test jobs, plus the `Docker` pull-request build. Distinguish the initial branch-push bootstrap failure described above from PR check failures. Inspect any failed required check before merging; local tests do not substitute for these hosted runs.

4. **Merge after successful review/checks — GHCR writes.** Merge the PR in GitHub. The merge triggers normal `main`/SHA publishing and enables daily monitoring. Verify `Actions → Docker` for the merge commit succeeds. Until the next step, the security check will reject the old release's incompatible Dockerfile.

5. **Publish a new compatible application release — GHCR writes.** Select a new stable `vX.Y.Z` tag; do not reuse an existing release. Fetch the merged source, verify that commit contains the new Dockerfile/publisher, then explicitly set the new version:

   ```bash
   set -euo pipefail
   PUBLISH_REPO=clajiness/qbop
   PUBLISH_IMAGE=ghcr.io/clajiness/qbop
   PUBLISH_RELEASE=vX.Y.Z # Replace with the actual new release before continuing.
   PUBLISH_PREVIOUS_RELEASE=v3.6.0 # Confirm the previous stable release at rollout time.
   [[ "$PUBLISH_RELEASE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
   git fetch origin main
   PUBLISH_COMMIT="$(git rev-parse origin/main)"
   git show "$PUBLISH_COMMIT:Dockerfile"
   git tag -a "$PUBLISH_RELEASE" "$PUBLISH_COMMIT" -m "$PUBLISH_RELEASE"
   git push origin "$PUBLISH_RELEASE"
   gh release create "$PUBLISH_RELEASE" --repo "$PUBLISH_REPO" --verify-tag \
     --title "$PUBLISH_RELEASE" --generate-notes
   ```

   The **tag push**, rather than GitHub Release creation, triggers `Docker`. A tag created solely by another workflow's `GITHUB_TOKEN` may not trigger that push workflow; use the maintainer's authenticated tag push shown here.

6. **Verify normal release publishing.** Select the `Docker` run for the new tag, not the earlier `main` push:

   ```bash
   gh run list --repo "$PUBLISH_REPO" --workflow docker.yml --event push --limit 10
   PUBLISH_NORMAL_RUN=REPLACE_WITH_RELEASE_RUN_ID
   gh run view "$PUBLISH_NORMAL_RUN" --repo "$PUBLISH_REPO" --json headBranch,headSha,event,conclusion
   gh run watch "$PUBLISH_NORMAL_RUN" --repo "$PUBLISH_REPO" --exit-status
   gh run view "$PUBLISH_NORMAL_RUN" --repo "$PUBLISH_REPO" --log
   ```

   Confirm the source SHA/version, unique staging digest, both architecture validations, and successful promotions. Confirm the `main` merge build has also finished before recording its digest.

7. **Record the production baseline.** The helpers below only read registry metadata:

   ```bash
   image_digest() {
     docker buildx imagetools inspect "$PUBLISH_IMAGE:$1" --format '{{json .Manifest}}' |
       ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("digest")'
   }
   snapshot_tags() {
     local tag tag_digest
     for tag in "$PUBLISH_RELEASE" "${PUBLISH_RELEASE%.*}" "${PUBLISH_RELEASE%%.*}" latest \
                "sha-${PUBLISH_COMMIT:0:12}" main "$PUBLISH_PREVIOUS_RELEASE"; do
       tag_digest="$(image_digest "$tag")"
       printf '%s\t%s\n' "$tag" "$tag_digest"
     done
   }
   snapshot_tags > qbop-tags-before.tsv
   PUBLISH_NORMAL_DIGEST="$(image_digest "$PUBLISH_RELEASE")"
   for tag in "${PUBLISH_RELEASE%.*}" "${PUBLISH_RELEASE%%.*}" latest; do
     test "$(image_digest "$tag")" = "$PUBLISH_NORMAL_DIGEST"
   done
   ```

   Keep this file outside commits. The SHA image may have been created by the earlier `main` build and therefore have a different digest/version label from the release aliases. Its source commit must match, and its existing digest must remain unchanged.

8. **Force a security rebuild — GHCR writes:**

   ```bash
   gh workflow run security-rebuild.yml --repo "$PUBLISH_REPO" --ref main -f force=true
   gh run list --repo "$PUBLISH_REPO" --workflow security-rebuild.yml --event workflow_dispatch --limit 5
   PUBLISH_SECURITY_RUN=REPLACE_WITH_JUST_DISPATCHED_RUN_ID
   gh run watch "$PUBLISH_SECURITY_RUN" --repo "$PUBLISH_REPO" --exit-status
   gh run view "$PUBLISH_SECURITY_RUN" --repo "$PUBLISH_REPO" --log
   ```

9. **Verify the refreshed mutable tags and staging digest:**

   ```bash
   snapshot_tags > qbop-tags-after.tsv
   PUBLISH_REFRESH_DIGEST="$(image_digest "$PUBLISH_RELEASE")"
   PUBLISH_ATTEMPT="$(gh api "repos/$PUBLISH_REPO/actions/runs/$PUBLISH_SECURITY_RUN" --jq .run_attempt)"
   test "$(image_digest "staging-$PUBLISH_SECURITY_RUN-$PUBLISH_ATTEMPT")" = "$PUBLISH_REFRESH_DIGEST"
   test "$PUBLISH_REFRESH_DIGEST" != "$PUBLISH_NORMAL_DIGEST"
   for tag in "$PUBLISH_RELEASE" "${PUBLISH_RELEASE%.*}" "${PUBLISH_RELEASE%%.*}" latest; do
     test "$(image_digest "$tag")" = "$PUBLISH_REFRESH_DIGEST"
   done
   docker buildx imagetools inspect "$PUBLISH_IMAGE@$PUBLISH_REFRESH_DIGEST"
   ```

   Confirm `linux/amd64` and `linux/arm64` (optionally `/v8`), source revision/version, pinned base digest, and successful runtime checks in the run log.

10. **Verify protected tags stayed unchanged:**

    ```bash
    for tag in "sha-${PUBLISH_COMMIT:0:12}" main "$PUBLISH_PREVIOUS_RELEASE"; do
      PUBLISH_BEFORE="$(awk -v tag="$tag" '$1 == tag {print $2}' qbop-tags-before.tsv)"
      test -n "$PUBLISH_BEFORE"
      test "$(image_digest "$tag")" = "$PUBLISH_BEFORE"
    done
    ```

11. **Run an ordinary non-forced check:**

    ```bash
    gh workflow run security-rebuild.yml --repo "$PUBLISH_REPO" --ref main -f force=false
    gh run list --repo "$PUBLISH_REPO" --workflow security-rebuild.yml --event workflow_dispatch --limit 5
    PUBLISH_CHECK_RUN=REPLACE_WITH_JUST_DISPATCHED_RUN_ID
    gh run watch "$PUBLISH_CHECK_RUN" --repo "$PUBLISH_REPO" --exit-status
    gh run view "$PUBLISH_CHECK_RUN" --repo "$PUBLISH_REPO" --log
    ```

    Expect `rebuild=false` and the publishing job skipped. If the upstream digest actually changed between runs, another rebuild is expected and this step can write GHCR images.

12. **Confirm scheduling after merge:**

    ```bash
    gh workflow list --repo "$PUBLISH_REPO" --all
    gh run list --repo "$PUBLISH_REPO" --workflow security-rebuild.yml --event schedule --limit 5
    ```

    Confirm **Upstream security rebuild** is active and inspect its first scheduled run after **07:23 UTC**. The schedule becomes eligible once the workflow is on `main`; execution can be delayed or dropped, and inactivity can disable schedules in public repositories after 60 days. Re-enable only if necessary with `gh workflow enable security-rebuild.yml --repo "$PUBLISH_REPO"`. See [GitHub schedule behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule). Scheduled runs can write GHCR images when a refresh is needed.
