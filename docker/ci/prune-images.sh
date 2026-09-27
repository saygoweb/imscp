#!/usr/bin/env bash
#
# Delete the CI images nothing needs any more from ghcr.io/saygoweb/imscp-ci.
#
#   docker/ci/prune-images.sh [--dry-run] [--keep <n>]    prune
#   docker/ci/prune-images.sh [--dry-run] --pr <number>   drop one PR's image
#
# Prune keeps:
#
#   * every version with a tag it does not recognise — `bookworm`, which every
#     plugin's Test job pulls, above all;
#   * the newest <n> (default 3) `bookworm-<sha>` versions, so a plugin can pin
#     a known-good image when a new build breaks;
#   * `pr-<number>` versions whose pull request is still open;
#
# and deletes the rest: older `bookworm-<sha>`, `pr-<number>` of closed pull
# requests, and untagged versions — left behind whenever `bookworm` or a
# `pr-<number>` moves on, and unreachable by name. Nothing else references
# them: the images are single-platform and pushed with plain `docker push`, so
# there are no multi-arch or attestation manifests pointing at untagged
# children.
#
# --pr <number> deletes that pull request's image only, open or not; CI runs it
# when the pull request closes.
#
# Needs GH_TOKEN with packages read/delete on the package and pull request read
# on the repository — in CI the workflow's GITHUB_TOKEN, since this repository
# published the package. PRUNE_VERSIONS_FILE and PRUNE_OPEN_PRS stand in for
# the two API reads, to try the decision on made-up input:
#
#   PRUNE_VERSIONS_FILE=versions.json PRUNE_OPEN_PRS='17 19' \
#       docker/ci/prune-images.sh --dry-run

set -euo pipefail

ORG="${PRUNE_ORG:-saygoweb}"
PACKAGE="${PRUNE_PACKAGE:-imscp-ci}"
REPO="${PRUNE_REPO:-saygoweb/imscp}"
KEEP=3
PR=''
DRY_RUN=no

die() { printf 'prune-images: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=yes; shift ;;
        --keep) KEEP="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
case "$KEEP" in ''|*[!0-9]*) die "--keep takes a number" ;; esac
case "$PR" in *[!0-9]*) die "--pr takes a pull request number" ;; esac

VERSIONS_API="/orgs/$ORG/packages/container/$PACKAGE/versions"

# Every version as {id, created_at, tags}. --paginate emits one array per page.
versions() {
    if [ -n "${PRUNE_VERSIONS_FILE:-}" ]; then
        cat "$PRUNE_VERSIONS_FILE"
    else
        gh api --paginate "$VERSIONS_API?per_page=100"
    fi | jq -s '[.[][] | {id, created_at, tags: .metadata.container.tags}]'
}

open_prs() {
    if [ -n "${PRUNE_OPEN_PRS+set}" ]; then
        printf '%s\n' $PRUNE_OPEN_PRS
    else
        gh api --paginate "/repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number'
    fi | jq -Rs '[split("\n")[] | select(length > 0) | tonumber]'
}

# The decision, as one jq program over the versions: an array of
# {id, tags, why} to delete.
if [ -n "$PR" ]; then
    doomed="$(versions | jq --arg tag "pr-$PR" '
        # Only a version whose tags are all PR tags: never take `bookworm` with it.
        [ .[] | select((.tags | index($tag)) and all(.tags[]; test("^pr-[0-9]+$")))
              | {id, tags, why: "its pull request has closed"} ]')"
else
    doomed="$(versions | jq --argjson keep "$KEEP" --argjson open "$(open_prs)" '
        def sha_tag: test("^bookworm-[0-9a-f]+$");
        def pr_tag:  test("^pr-[0-9]+$");
        # A tag it does not recognise (bookworm above all) protects a version.
        def protected: any(.tags[]; (sha_tag or pr_tag) | not);

        (map(select((.tags | length) > 0 and (protected | not)
                    and any(.tags[]; sha_tag)))
         | sort_by(.created_at) | reverse | .[$keep:] | map(.id)) as $old_shas
        | [ .[]
            | if (.tags | length) == 0 then
                  {id, tags, why: "untagged"}
              elif protected then
                  empty
              elif (.id | IN($old_shas[])) then
                  {id, tags, why: "older than the newest \($keep) bookworm-<sha>"}
              elif all(.tags[]; pr_tag)
                   and all(.tags[]; (ltrimstr("pr-") | tonumber) | IN($open[]) | not) then
                  {id, tags, why: "its pull request has closed"}
              else
                  empty
              end ]')"
fi

count="$(jq length <<< "$doomed")"
if [ "$count" -eq 0 ]; then
    echo "nothing to delete from ghcr.io/$ORG/$PACKAGE"
    exit 0
fi

jq -r '.[] | "\(.id)\t\(if (.tags | length) == 0 then "(untagged)" else (.tags | join(",")) end)\t\(.why)"' <<< "$doomed" |
while IFS=$'\t' read -r id tags why; do
    if [ "$DRY_RUN" = yes ]; then
        printf 'would delete %s %s: %s\n' "$id" "$tags" "$why"
    else
        gh api --silent -X DELETE "$VERSIONS_API/$id"
        printf 'deleted %s %s: %s\n' "$id" "$tags" "$why"
    fi
done

[ "$DRY_RUN" = yes ] && echo "$count version(s) would be deleted (dry run)" \
    || echo "$count version(s) deleted"
