# Engine test suite, phases 0 and 1: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use cjp:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task, wave by wave, following the Execution Schedule. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the CI image to Debian trixie, then build the engine's test harness: a stub kit for unit tests, fixtures and a driver for integration tests, a runner, CI jobs, and a first integration test (`named`) that runs the real request pipeline on the image.

**Architecture:** Unit tests (`test/perl/unit/`) run the checkout's engine code with its edges stubbed by `iMSCPTest::Stub`: shell, database, singletons, config, events and paths. They need no root and no install. Integration tests (`test/perl/integration/`) run as root on a booted, throwaway CI image. They queue panel-shaped rows (`iMSCPTest::Fixture`), run the real `imscp-rqst-mngr` (`iMSCPTest::Engine`), and check the results through the services. `test/run.sh` is the single entry point. CI runs the unit tests inside the published image without booting it, and runs the integration tests on the image that was just built.

**Tech Stack:** Perl 5 with Test::More and prove; POSIX sh and bash; Docker; GitHub Actions; jq; Devel::Cover (`libdevel-cover-perl`); Net::DNS.

**Spec:** `docs/superpowers/specs/2026-10-21-engine-test-suite-design.md`

## Global Constraints

- Tests live outside the source tree: `test/perl/unit/`, `test/perl/integration/`, `test/perl/lib/`, `test/ci/`. Never put anything in `engine/t` or similar.
- Unit tests need no root, no network and no database, and write only under `sandbox()`. A unit test that reaches outside its sandbox fails; it does not skip.
- Integration tests run only on the throwaway CI image. `test/run.sh integration` refuses to run unless `/etc/imscp/ci-image` exists.
- Engine source (`engine/`) is not refactored for testability. If a case can't be tested with the kit, stop and ask the user, proposing the seam you would add.
- Integration tests assert behaviour, never which implementation is installed. Read paths from the installed server's own config (`$server->{'config'}`), never hard-code them.
- Fixture names are `<label>-<pid>.test`.
- Integration test files run one at a time (no `prove -j`). Unit tests run with `-j4`.
- The CI image becomes `ghcr.io/saygoweb/imscp-ci:trixie`, with `:trixie-<sha7>` from main and `:pr-<n>` from same-repo PRs. Bookworm is not built any more, and the existing `:bookworm` tag is left alone (protected and frozen).
- Match the surrounding code: four-space indent and opening braces of `sub` blocks on their own line in Perl modules (as in `engine/PerlLib`); POSIX `sh` for `test/run.sh`; bash with `lib.sh` for `docker/ci/*.sh`.
- This machine overheats under parallel load (see `~/.claude-personal/CLAUDE.md`). Before an image build or parallel subagents, check `cat /sys/devices/system/cpu/intel_pstate/no_turbo` is `1`; if not, ask the user to set it. Run at most 4 test-heavy agents at once.
- Commit messages follow the repository's style (`area: what changed`, wrapped prose body) and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A command given as an array ref** (`execute( [ 'ls', '-l', $dir ] )`): `stub_execute` must match its rules against the joined command line and record it that way. Pinned in Task 5.
2. **A stub called without keeping its guard** (`stub_db(...);` in void context): the guard would drop immediately, undoing the stub before it was ever used. The kit must croak. Pinned in Tasks 3, 5, 6, 7.
3. **An engine run that exits 0 but leaves a row with an error in its status column**: `is_ok` must fail and show the error text. Pinned in Task 10's unit test of `iMSCPTest::Engine`.
4. **`test/run.sh integration` on the development stack or a laptop** (no marker): it must refuse with exit 2 and name the marker, before touching anything. Pinned in Task 4.
5. **A SQL statement no `stub_db` rule matches**: it must fail the test and die, as DBI does under `RaiseError`, rather than return `undef` and let the code under test carry on. Pinned in Task 6.

## Execution Schedule

| Wave | Tasks | Model | Notes |
|------|-------|-------|-------|
| 1 | Task 1, Task 2 | sonnet, sonnet | Phase 0, in parallel: disjoint files (`prune-images.sh` and `test/ci/prune-images.t`, versus the suite defaults). On branch `worktree-test-perl-layout`. |
| CP0 | — | — | plan base..end of wave 1. Code-review medium, plus spec check (spec §"Trixie replaces bookworm"). |
| C1 | Controller | — | Open PR A ("ci: move the CI image to trixie"). Start the local trixie image build in the background (Task 2, step 6), and keep it running through waves 2–3. Create branch `engine-test-harness` from PR A's head for waves 2 onwards. |
| 2 | Task 3, Task 4 | sonnet, sonnet | In parallel: `iMSCPTest::Guard` and `Stub::Symbol`, versus `test/run.sh`. Disjoint files. |
| 3 | Task 5, Task 6, Task 7 | sonnet, sonnet, sonnet | In parallel. Each consumes Task 3's `Guard` and `stub_method` / `stub_singleton`, and each writes its own module and test file. |
| 4 | Task 8, Task 9 | sonnet, sonnet | In parallel: the façade and test migration, versus `engine-test.sh`. Disjoint files. |
| CP1 | — | — | `engine-test-harness` base..end of wave 4. Code-review medium, plus spec check (spec §"Unit kit", §"Runner and CI"). May run concurrently with wave 5: Task 10 adds new files only. |
| 5 | Task 10 | opus | Needs the local image from C1 and `engine-test.sh` from Task 9. Exclusive resource: one booted image container. |
| 6 | Task 11 | sonnet | CI workflows. Consumes `run.sh` and `engine-test.sh`. |
| CP2 | — | — | `engine-test-harness` base..end of wave 6. Code-review medium, plus spec check (full spec, phases 0–1). |
| 7 | Controller | — | Push and open PR B. Wait for CI: `:pr-<n>` built, smoke-tested and integration-tested. Run the plugins against `:pr-<A>` (Task 12). Merge as the user asks. |

---

## Phase 0: the trixie CI image

### Task 1: Prune rules that know any suite

**Files:**
- Modify: `docker/ci/prune-images.sh` (header comment, and the jq program in the `else` branch)
- Create: `test/ci/prune-images.t`

**Interfaces:**
- Consumes: none.
- Produces: `prune-images.sh` recognises `<suite>-<sha>` tags (a suite is `[a-z][a-z0-9]*`; a sha is 7–40 hex digits) and keeps the newest `--keep` per suite. `pr-<n>` is never mistaken for a sha tag. The output format is unchanged: `would delete <id> <tags>: <why>`.

- [ ] **Step 1: Write the failing test**

Create `test/ci/prune-images.t`:

```perl
#!/usr/bin/perl

# docker/ci/prune-images.sh decides what to delete from ghcr.io/saygoweb/imscp-ci.
# Tried on made-up versions through the script's own PRUNE_VERSIONS_FILE and
# PRUNE_OPEN_PRS stand-ins, so no token or network is needed:
#
#   test/run.sh ci

use strict;
use warnings;
use FindBin;
use File::Temp qw/ tempfile /;
use JSON::PP;
use Test::More;

plan skip_all => 'needs jq' unless system( 'jq --version >/dev/null 2>&1' ) == 0;

my $script = "$FindBin::Bin/../../docker/ci/prune-images.sh";

# [ id, created_at, tags ]
my @versions = (
    [ 1, '2026-01-01T00:00:00Z', [ 'bookworm' ] ],
    [ 2, '2026-10-20T00:00:00Z', [ 'trixie', 'trixie-aaaaaaa' ] ],
    [ 3, '2026-10-01T00:00:00Z', [ 'trixie-1111111' ] ],
    [ 4, '2026-10-02T00:00:00Z', [ 'trixie-2222222' ] ],
    [ 5, '2026-10-03T00:00:00Z', [ 'trixie-3333333' ] ],
    [ 6, '2026-10-04T00:00:00Z', [ 'trixie-4444444' ] ],
    [ 7, '2026-10-05T00:00:00Z', [ 'trixie-5555555' ] ],
    [ 8, '2026-01-02T00:00:00Z', [ 'bookworm-8888888' ] ],
    [ 9, '2026-01-03T00:00:00Z', [ 'bookworm-9999999' ] ],
    [ 10, '2026-01-04T00:00:00Z', [ 'bookworm-aaaaaa0' ] ],
    [ 11, '2026-01-05T00:00:00Z', [ 'bookworm-bbbbbb0' ] ],
    [ 12, '2026-10-06T00:00:00Z', [ 'pr-12' ] ],
    [ 13, '2026-10-07T00:00:00Z', [ 'pr-17' ] ],
    [ 14, '2026-10-08T00:00:00Z', [] ],
    [ 15, '2026-10-09T00:00:00Z', [ 'pr-1234567' ] ],
);

my ( $fh, $file ) = tempfile( UNLINK => 1 );
print $fh encode_json( [
    map { { id => $_->[0], created_at => $_->[1], metadata => { container => { tags => $_->[2] } } } } @versions
] );
close $fh;

sub doomed
{
    my ( @args ) = @_;
    my $out = `PRUNE_VERSIONS_FILE='$file' PRUNE_OPEN_PRS='17' '$script' --dry-run @args 2>&1`;
    is( $? >> 8, 0, "prune-images.sh @args exits 0" ) or diag( $out );
    [ sort { $a <=> $b } $out =~ /^would delete (\d+) /mg ];
}

is_deeply(
    doomed(),
    [ 3, 4, 8, 12, 14, 15 ],
    'keeps the bare suite tags, the newest three <suite>-<sha> of each suite and open PRs'
);
is_deeply( doomed( '--keep', 1 ), [ 3, 4, 5, 6, 8, 9, 10, 12, 14, 15 ], '--keep counts per suite' );
is_deeply( doomed( '--pr', 12 ), [ 12 ], '--pr deletes that pull request\'s image only' );

done_testing();
```

The expected sets follow from the rules:
- 1 and 2 carry a bare suite tag, so they are protected.
- trixie sha versions 3–7: the newest three are 5, 6 and 7, so 3 and 4 go.
- bookworm sha versions 8–11: the newest three are 9, 10 and 11, so 8 goes.
- PR 12 is closed and PR 17 is open.
- 14 is untagged.
- 15 is `pr-1234567`. It must count as a PR tag, never a sha, and that PR is closed.

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -v test/ci/prune-images.t`

Expected: FAIL on the first `is_deeply`. Today's script treats all of 3–7 as unrecognised tags and so protects them.

- [ ] **Step 3: Generalise the jq program**

In `docker/ci/prune-images.sh`, replace the `else` branch's jq program (from `doomed="$(versions | jq --argjson keep` to the closing `]')"` of that branch) with:

```bash
    doomed="$(versions | jq --argjson keep "$KEEP" --argjson open "$(open_prs)" '
        def pr_tag:  test("^pr-[0-9]+$");
        def sha_tag: test("^[a-z][a-z0-9]*-[0-9a-f]{7,40}$") and (pr_tag | not);
        def suite:   sub("-[0-9a-f]+$"; "");
        # A tag it does not recognise (trixie above all) protects a version.
        def protected: any(.tags[]; (sha_tag or pr_tag) | not);

        (map(select((.tags | length) > 0 and (protected | not)
                    and any(.tags[]; sha_tag)))
         | group_by([.tags[] | select(sha_tag) | suite][0])
         | map(sort_by(.created_at) | reverse | .[$keep:])
         | add // []
         | map(.id)) as $old_shas
        | [ .[]
            | if (.tags | length) == 0 then
                  {id, tags, why: "untagged"}
              elif protected then
                  empty
              elif (.id | IN($old_shas[])) then
                  {id, tags, why: "older than the newest \($keep) <sha> versions of its suite"}
              elif all(.tags[]; pr_tag)
                   and all(.tags[]; (ltrimstr("pr-") | tonumber) | IN($open[]) | not) then
                  {id, tags, why: "its pull request has closed"}
              else
                  empty
              end ]')"
```

In the `--pr` branch, change the comment `never take \`bookworm\` with it` to `never take a suite tag with it`.

Rewrite the header's list of what is kept and deleted:

```bash
# Prune keeps:
#
#   * every version with a tag it does not recognise: a bare suite tag such as
#     `trixie`, which every plugin's Test job pulls, above all. The retired
#     `bookworm` is kept that way too: frozen, never deleted;
#   * the newest <n> (default 3) `<suite>-<sha>` versions of each suite, so a
#     plugin can pin a known-good image when a new build breaks;
#   * `pr-<number>` versions whose pull request is still open;
#
# and deletes the rest: older `<suite>-<sha>`, `pr-<number>` of closed pull
# requests, and untagged versions — left behind whenever a suite tag or a
# `pr-<number>` moves on, and unreachable by name. Nothing else references
```

Keep the rest of the header as it is.

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -v test/ci/prune-images.t`

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add docker/ci/prune-images.sh test/ci/prune-images.t
git commit -m "ci: prune <suite>-<sha> images per suite, not only bookworm

The CI image moves to trixie. Prune now recognises a sha tag of any
suite and keeps the newest three of each, so the retired bookworm
images run down while trixie's are kept. A bare suite tag still
protects its version, so :bookworm is frozen, not deleted.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: Build, publish and default to trixie

**Files:**
- Modify: `docker/ci/build-image.sh` (default suite; marker before "tidying")
- Modify: `docker/Dockerfile` (`ARG DEBIAN_SUITE`; `libdevel-cover-perl`)
- Modify: `docker/docker-compose.yml:26-27`, `docker/imscp:44`, `docker/.env.example:11-13`
- Modify: `docker/ci/plugin-test.sh:15,29`, `.github/workflows/plugin-test.yml:35`
- Modify: `.github/workflows/ci-image.yml` (header comment; "Choose tags"; the suite passed to the build)
- Modify: `docker/README.md` (the CI image section; the `DEBIAN_SUITE` description)

**Interfaces:**
- Consumes: none.
- Produces:
  - Images tagged `ghcr.io/saygoweb/imscp-ci:trixie`, `:trixie-<sha7>` and `:pr-<n>`.
  - Every image has the file `/etc/imscp/ci-image`, which Task 4's `test/run.sh` checks for.
  - Every image has `Devel::Cover`, which Task 4's `--cover` uses.
  - `$IMSCP_CI_IMAGE` defaults to `ghcr.io/saygoweb/imscp-ci:trixie` wherever it is read.

- [ ] **Step 1: Write the check that fails today**

Run:

```bash
grep -rn 'bookworm' docker/ci/build-image.sh docker/Dockerfile docker/docker-compose.yml docker/imscp docker/.env.example docker/ci/plugin-test.sh .github/workflows/plugin-test.yml .github/workflows/ci-image.yml
grep -n 'ci-image' docker/ci/build-image.sh
grep -n 'libdevel-cover-perl' docker/Dockerfile
```

Expected: the first command lists the bookworm defaults; the second and third print nothing.

- [ ] **Step 2: Switch the defaults**

Make these exact edits:
- `docker/ci/build-image.sh`: `DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"` becomes `DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"`.
- `docker/Dockerfile`: `ARG DEBIAN_SUITE=bookworm` becomes `ARG DEBIAN_SUITE=trixie`. In the first `RUN apt-get … install` list, add `libdevel-cover-perl \` on the line after `perl \`. Extend that layer's comment with one line: `# Devel::Cover is for test/run.sh unit --cover.`
- `docker/docker-compose.yml`: both `${DEBIAN_SUITE:-bookworm}` become `${DEBIAN_SUITE:-trixie}`.
- `docker/imscp`: `export DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"` becomes `export DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"`.
- `docker/.env.example`: change the comment to `# see ../autoinstaller/Packages/debian-*.xml. trixie (13) is the default and what production runs; bookworm (12) still installs.` and the line after it to `#DEBIAN_SUITE=trixie`.
- `docker/ci/plugin-test.sh`: in both the usage comment and `IMAGE="${IMSCP_CI_IMAGE:-…}"`, `ghcr.io/saygoweb/imscp-ci:bookworm` becomes `ghcr.io/saygoweb/imscp-ci:trixie`.
- `.github/workflows/plugin-test.yml`: `default: ghcr.io/saygoweb/imscp-ci:bookworm` becomes `default: ghcr.io/saygoweb/imscp-ci:trixie`.

- [ ] **Step 3: Mark the image as a throwaway CI image**

In `docker/ci/build-image.sh`, insert this before `log "tidying"`:

```bash
# Marks the image as a throwaway CI server. test/run.sh runs the integration
# tests, which add and delete real customers, only where this file exists; the
# development stack never has it.
docker exec "$CONTAINER" sh -c "printf 'i-MSCP CI image, built from %s\n' '$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)' > /etc/imscp/ci-image"
```

- [ ] **Step 4: Publish trixie from ci-image.yml**

In `.github/workflows/ci-image.yml`:

Rewrite the header's tag lines:

```yaml
#   main                 -> :trixie and :trixie-<sha>
#   a same-repo PR       -> :pr-<number>, for trying plugin CI against the change
#   weekly               -> :trixie again, so the image does not fall behind
#                           the Debian and sury archives
#
# Trixie is what production runs. The bookworm image is no longer built: its
# last :bookworm stays published, frozen, for anything still pinned to it.
```

In "Choose tags", change the `else` line to:

```bash
              echo "tags=$IMAGE:trixie $IMAGE:trixie-${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
```

Give the "Build and install" step the suite:

```yaml
      - name: Build and install
        env:
          DEBIAN_SUITE: trixie
        run: docker/ci/build-image.sh ${{ steps.tags.outputs.tags }}
```

- [ ] **Step 5: Update docker/README.md**

- Line 139: `ghcr.io/saygoweb/imscp-ci:bookworm` becomes `ghcr.io/saygoweb/imscp-ci:trixie`.
- Line 149: rewrite the sentence about what is pruned so it says `<suite>-<sha>` and the newest three per suite. Add: "`:bookworm`, from before the move to trixie, is never pruned and never rebuilt."
- Line 205: the `DEBIAN_SUITE` description says `trixie` (the default) or `bookworm`.

Then run:

```bash
grep -rn 'bookworm' docker .github | grep -v -e 'debian-bookworm.xml' -e 'configs/debian/bookworm'
```

Expected: only the deliberate mentions remain. These are the README and `ci-image.yml` sentences about the frozen `:bookworm`, `.env.example`'s "bookworm (12) still installs", the prune header, and `test/ci/prune-images.t`'s data, which is outside `docker`.

- [ ] **Step 6: Build the trixie image locally, and smoke-test it (controller, wave C1, in the background)**

Check `cat /sys/devices/system/cpu/intel_pstate/no_turbo` prints `1`. If it doesn't, ask the user to run `echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo` first.

Run (20–40 minutes):

```bash
bash -n docker/ci/build-image.sh docker/ci/plugin-test.sh docker/imscp
docker/ci/build-image.sh imscp-ci:trixie-local
docker/ci/smoke-test.sh imscp-ci:trixie-local
docker run --rm --entrypoint cat imscp-ci:trixie-local /etc/imscp/ci-image
docker run --rm --entrypoint perl imscp-ci:trixie-local -MDevel::Cover -e 'print "Devel::Cover $Devel::Cover::VERSION\n"'
```

Expected:
- The build ends with `built: imscp-ci:trixie-local`.
- The smoke test prints `services up`, `database answers`, `panel bootstrapped` and the configuration-files line.
- The marker prints `i-MSCP CI image, built from <sha>`.
- Devel::Cover prints its version.

If the trixie install itself fails, stop and report it: phase 0's premise is that trixie installs.

- [ ] **Step 7: Commit**

```bash
git add docker/ci/build-image.sh docker/Dockerfile docker/docker-compose.yml docker/imscp docker/.env.example docker/ci/plugin-test.sh .github/workflows/plugin-test.yml .github/workflows/ci-image.yml docker/README.md
git commit -m "ci: build, test and publish the CI image on trixie

Production runs Debian 13, so the CI image plugins test against moves
from bookworm to trixie: :trixie and :trixie-<sha> from main, :pr-<n>
for pull requests. Every default that named bookworm now names trixie,
and plugins calling plugin-test.yml@main follow automatically.

The image also gains /etc/imscp/ci-image, which marks it as throwaway
for the engine's integration tests, and Devel::Cover for coverage.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 1: the harness

All of Phase 1 is on branch `engine-test-harness`, created at wave C1 from PR A's head.

### Task 3: Guards and symbol stubs

**Files:**
- Create: `test/perl/lib/iMSCPTest/Guard.pm`
- Create: `test/perl/lib/iMSCPTest/Stub/Symbol.pm`
- Test: `test/perl/unit/iMSCPTest-Stub-Symbol.t`

**Interfaces:**
- Consumes: `Common::SingletonClass` (`engine/PerlLib/Common/SingletonClass.pm`). It keeps the instance in `${"<Class>::_instance"}`.
- Produces:
  - `iMSCPTest::Guard->new( \&restore, %fields )`: calls `restore` once, when the guard is destroyed. `%fields` are stored in the object for subclasses to read.
  - `iMSCPTest::Guard::require_kept( wantarray, $name )`: croaks when called in void context. The message contains `keep it`.
  - `iMSCPTest::Stub::Symbol::stub_method( $class, $method, \&code )`: returns a guard. It keeps the original's prototype, and restores the original, or removes the sub if there was none.
  - `iMSCPTest::Stub::Symbol::stub_singleton( $class, $obj )`: returns a guard. It sets `${"${class}::_instance"}` and restores the previous value.

- [ ] **Step 1: Write the failing test**

Create `test/perl/unit/iMSCPTest-Stub-Symbol.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Stub::Symbol: stubs for one sub and for a singleton's instance,
# undone when their guard goes.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub::Symbol qw/ stub_method stub_singleton /;

{
    package Sample;
    sub plain { 'real' }
    sub proto ($;$) { 'real' }
}

{
    my $guard = stub_method( 'Sample', 'plain', sub { 'stub' } );
    is( Sample->plain, 'stub', 'stub_method replaces the sub' );
}
is( Sample->plain, 'real', 'and puts it back when its guard goes' );

{
    my $guard = stub_method( 'Sample', 'proto', sub { 'stub' } );
    is( prototype( \&Sample::proto ), '$;$', 'the stub keeps the original prototype' );
    is( Sample::proto( 1 ), 'stub', 'and is called' );
}
is( Sample::proto( 1 ), 'real', 'a prototyped sub is put back' );

{
    my $guard = stub_method( 'Sample', 'added', sub { 'new' } );
    is( Sample->added, 'new', 'a sub that did not exist can be stubbed' );
}
ok( !Sample->can( 'added' ), 'and is removed again' );

like(
    ( eval { stub_method( 'Sample', 'plain', sub { 'stub' } ); 1 } ? '' : $@ ),
    qr/keep it/,
    'a guard thrown away at once is refused'
);
is( Sample->plain, 'real', 'and the sub is left alone' );

{
    package Single;
    use parent 'Common::SingletonClass';
}

my $fake = bless {}, 'Fake';
{
    my $guard = stub_singleton( 'Single', $fake );
    is( Single->getInstance(), $fake, 'stub_singleton sets the instance getInstance() returns' );
}
isnt( Single->getInstance(), $fake, 'and restores it' );

my $real = Single->getInstance();
{
    my $guard = stub_singleton( 'Single', $fake );
}
is( Single->getInstance(), $real, 'an existing instance comes back' );

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib -v test/perl/unit/iMSCPTest-Stub-Symbol.t`

Expected: FAIL with `Can't locate iMSCPTest/Stub/Symbol.pm`.

- [ ] **Step 3: Write the guard**

Create `test/perl/lib/iMSCPTest/Guard.pm`:

```perl
package iMSCPTest::Guard;

# Undoes a stub when it goes out of scope. Every stub in the kit returns one:
# keep it in a lexical for as long as the stub should last, e.g. file-wide
#
#   my $db = stub_db( ... );

use strict;
use warnings;
use Carp qw/ croak /;

sub new
{
    my ( $class, $restore, %fields ) = @_;

    ref $restore eq 'CODE' or croak( 'A guard needs a restore sub' );
    bless { %fields, _restore => $restore }, $class;
}

# A stub called in void context would be undone before it was ever used.
sub require_kept
{
    my ( $wantarray, $name ) = @_;

    defined $wantarray or croak(
        "$name returns a guard that undoes it when dropped; keep it: my \$guard = $name( ... )"
    );
}

sub DESTROY
{
    my ( $self ) = @_;

    local ( $@, $!, $? );
    my $restore = delete $self->{'_restore'} or return;
    $restore->();
}

1;
```

- [ ] **Step 4: Write the symbol stubs**

Create `test/perl/lib/iMSCPTest/Stub/Symbol.pm`:

```perl
package iMSCPTest::Stub::Symbol;

# Stubs for a single sub and for a singleton's instance.
#
#   my $compile = stub_method( 'Servers::named::bind', '_compileZone', sub { 0 } );
#   my $net     = stub_singleton( 'iMSCP::Net', $fakeNet );
#
# Load the class before stubbing one of its subs: loading it afterwards would
# define the real sub over the stub.

use strict;
use warnings;
use Carp qw/ croak /;
use Scalar::Util ();
use iMSCPTest::Guard;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_method stub_singleton /;

sub stub_method
{
    my ( $class, $method, $code ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_method' );
    ref $code eq 'CODE' or croak( 'stub_method needs a code ref' );

    no strict 'refs';
    no warnings qw/ redefine prototype /;

    my $name = "${class}::$method";
    my $old = defined &{ $name } ? \&{ $name } : undef;
    my $proto = $old ? prototype $old : undef;
    &Scalar::Util::set_prototype( $code, $proto ) if defined $proto;
    *{ $name } = $code;

    iMSCPTest::Guard->new( sub {
        no strict 'refs';
        no warnings qw/ redefine prototype /;

        if ( $old ) {
            *{ $name } = $old;
            return;
        }

        # Remove the sub but keep whatever else shares its glob.
        my $glob = \*{ $name };
        my %slots = map { $_ => *{ $glob }{$_} } grep { defined *{ $glob }{$_} } qw/ SCALAR ARRAY HASH IO /;
        delete ${"${class}::"}{$method};
        *{ $name } = $slots{$_} for keys %slots;
    } );
}

sub stub_singleton
{
    my ( $class, $obj ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_singleton' );

    no strict 'refs';
    my $slot = \${"${class}::_instance"};
    my $old = ${ $slot };
    ${ $slot } = $obj;

    iMSCPTest::Guard->new( sub { ${ $slot } = $old } );
}

1;
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `prove -Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib -v test/perl/unit/iMSCPTest-Stub-Symbol.t`

Expected: PASS, 12 tests.

- [ ] **Step 6: Commit**

```bash
git add test/perl/lib/iMSCPTest/Guard.pm test/perl/lib/iMSCPTest/Stub/Symbol.pm test/perl/unit/iMSCPTest-Stub-Symbol.t
git commit -m "test: scope guards and sub/singleton stubs for the unit kit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: `test/run.sh`, the single entry point

**Files:**
- Create: `test/run.sh` (mode 755)
- Create: `test/ci/run-sh.t`
- Modify: `.gitignore`: add `/cover_db/`

**Interfaces:**
- Consumes: none. The directories it runs need not exist yet, because `prove` reports them.
- Produces:
  - `test/run.sh unit [--cover] [files…]`
  - `test/run.sh integration [files…]`
  - `test/run.sh ci`
  - `test/run.sh all`
  - Exit codes: 0 when every test passes, 1 when any fails, 2 for usage errors and refusals.
  - Environment: `IMSCP_ENGINE_DIR` (default `/var/www/imscp/engine`), `COVER_DIR` (default `<repo>/cover_db`), `PROVE_ARGS`.
  - `--cover` writes an HTML report to `$COVER_DIR/html/coverage.html`.

- [ ] **Step 1: Write the failing test**

Create `test/ci/run-sh.t`:

```perl
#!/usr/bin/perl

# test/run.sh: what it runs, from wherever it is started, and what it refuses.

use strict;
use warnings;
use FindBin;
use File::Temp qw/ tempdir /;
use Test::More;

my $run = "$FindBin::Bin/../run.sh";
my $dir = tempdir( CLEANUP => 1 );

sub spit
{
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh;
}

spit( "$dir/pass.t", "use Test::More; pass( 'passes' ); done_testing();\n" );
spit( "$dir/fail.t", "use Test::More; fail( 'fails' ); done_testing();\n" );

my $out = `cd '$dir' && sh '$run' unit '$dir/pass.t' 2>&1`;
is( $? >> 8, 0, 'unit runs the named file, started from another directory' ) or diag( $out );

$out = `sh '$run' unit '$dir/fail.t' 2>&1`;
is( $? >> 8, 1, 'unit exits 1 when a test fails' ) or diag( $out );

$out = `sh '$run' nonsense 2>&1`;
is( $? >> 8, 2, 'an unknown command exits 2' );
like( $out, qr/usage/i, 'and prints the usage' );

SKIP: {
    skip 'this host is a CI image', 2 if -e '/etc/imscp/ci-image';
    $out = `sh '$run' integration 2>&1`;
    is( $? >> 8, 2, 'integration refuses to run off the CI image' );
    like( $out, qr{/etc/imscp/ci-image}, 'and names the marker it looked for' );
}

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -v test/ci/run-sh.t`

Expected: FAIL. `sh: …/run.sh: No such file`, and exit 127 rather than 0.

- [ ] **Step 3: Write the runner**

Create `test/run.sh`:

```sh
#!/bin/sh
# Run the test suite. The single entry point for people and for CI.
#
#   test/run.sh unit [--cover] [files...]   the engine's unit tests: anywhere, as anyone
#   test/run.sh integration [files...]      on the throwaway CI image only, as root
#   test/run.sh ci                          the tests of the CI scripts themselves
#   test/run.sh all                         unit, then integration
#
# Unit tests load the checkout's engine. Integration tests drive the installed
# one, which is the checkout's only when docker/ci/engine-test.sh --link put it
# there. See test/perl/README.md.
#
# Environment:
#   IMSCP_ENGINE_DIR  the installed engine, default /var/www/imscp/engine
#   COVER_DIR         where --cover writes, default ./cover_db
#   PROVE_ARGS        extra prove options, e.g. "--formatter TAP::Formatter::JUnit"
#
# Exits 0 when every test passes, 1 when any fails, 2 when it refuses to run.

set -u

cd "$(dirname "$0")/.." || exit 2

MARKER=/etc/imscp/ci-image

usage() {
    { echo 'usage:'; sed -n '3,6p' "$0" | sed 's/^# /  /'; } >&2
    exit 2
}

unit() {
    cover=no
    if [ "${1:-}" = --cover ]; then
        cover=yes
        shift
    fi
    [ $# -gt 0 ] || set -- test/perl/unit

    if [ "$cover" = no ]; then
        # shellcheck disable=SC2086
        prove -r -j4 --timer -Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib ${PROVE_ARGS:-} "$@"
        return
    fi

    COVER_DIR="${COVER_DIR:-$PWD/cover_db}"
    rm -rf "$COVER_DIR"
    # Only the engine's own code: not the tests, the vendored CPAN modules or
    # anything loaded by absolute path from the system.
    HARNESS_PERL_SWITCHES="-MDevel::Cover=-db,$COVER_DIR,-silent,1,+ignore,^test/,+ignore,^engine/PerlVendor/,+ignore,^/"
    export HARNESS_PERL_SWITCHES
    # shellcheck disable=SC2086
    prove -r -j4 --timer -Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib ${PROVE_ARGS:-} "$@"
    rc=$?
    cover -silent -report html -outputdir "$COVER_DIR/html" "$COVER_DIR" >/dev/null || rc=1
    echo "coverage report: $COVER_DIR/html/coverage.html"
    return $rc
}

integration() {
    if [ ! -f "$MARKER" ]; then
        echo "$0: $MARKER is missing. The integration tests add and delete real" >&2
        echo "customers, so they run only on a throwaway CI image: docker/ci/engine-test.sh" >&2
        return 2
    fi
    [ "$(id -u)" -eq 0 ] || { echo "$0: the integration tests must run as root" >&2; return 2; }

    engine="${IMSCP_ENGINE_DIR:-/var/www/imscp/engine}"
    [ $# -gt 0 ] || set -- test/perl/integration
    # One at a time: each engine run processes every pending row on the server.
    # shellcheck disable=SC2086
    prove -r --timer -I"$engine/PerlLib" -I"$engine/PerlVendor" -Itest/perl/lib ${PROVE_ARGS:-} "$@"
}

ci() {
    # shellcheck disable=SC2086
    prove --timer ${PROVE_ARGS:-} test/ci
}

normalise() {
    # prove exits 1 for failures and higher for its own errors; fold to 1.
    [ "$1" -eq 0 ] && return 0
    [ "$1" -eq 2 ] && return 2
    return 1
}

case "${1:-}" in
    unit|integration|ci)
        cmd=$1
        shift
        "$cmd" "$@"
        normalise $?
        exit $?
        ;;
    all)
        shift
        unit; u=$?
        integration; i=$?
        [ "$u" -eq 0 ] && [ "$i" -eq 0 ] && exit 0
        exit 1
        ;;
    *)
        usage
        ;;
esac
```

Run `chmod 755 test/run.sh`, and add the line `/cover_db/` to `.gitignore`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `prove -v test/ci/run-sh.t && sh test/run.sh unit test/perl/iMSCP-File-copyFile.t test/perl/Servers-named-bind-subdomain.t`

Expected: PASS, 6 tests. The two existing tests then pass through the runner (they move to `unit/` in Task 8).

- [ ] **Step 5: Commit**

```bash
git add test/run.sh test/ci/run-sh.t .gitignore
git commit -m "test: test/run.sh, one entry point for unit, integration and CI tests

Integration tests refuse to run unless /etc/imscp/ci-image marks a
throwaway CI image, so they can never add or delete customers on the
development stack.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: `stub_execute`

**Files:**
- Create: `test/perl/lib/iMSCPTest/Stub/Execute.pm`
- Test: `test/perl/unit/iMSCPTest-Stub-Execute.t`

**Interfaces:**
- Consumes:
  - `iMSCPTest::Guard` and `iMSCPTest::Guard::require_kept` (Task 3).
  - `iMSCP::Execute::execute( $command; \$stdout, \$stderr )`, which returns an exit code.
  - `iMSCP::Execute::executeNoWait( $command; \&onStdout, \&onStderr )`.
- Produces: `iMSCPTest::Stub::Execute::stub_execute( qr/…/ => [ $exit, $stdout, $stderr ] | sub { my ( $command ) = @_; [ … ] }, … )`. It returns a guard with:
  - `->commands`: the list of command lines, with array commands joined by spaces.
  - On restore, every alias of the stub, including one imported after stubbing, gets the real sub back.

- [ ] **Step 1: Write the failing test**

Create `test/perl/unit/iMSCPTest-Stub-Execute.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Stub::Execute: commands run through iMSCP::Execute are answered by
# the test, in every module that imported execute(), and never reach a shell.

use strict;
use warnings;
use Test::More;
use iMSCP::Execute ();
use iMSCPTest::Stub::Symbol qw/ stub_method /;
use iMSCPTest::Stub::Execute qw/ stub_execute /;

{
    package Caller;
    use iMSCP::Execute;
    sub string { my $rs = execute( 'echo hi', \my $out, \my $err ); [ $rs, $out, $err ] }
    sub list { my $rs = execute( [ 'ls', '-l', '/nowhere' ], \my $out, \my $err ); [ $rs, $out, $err ] }
    sub nowait { my @lines; my $rs = executeNoWait( 'tail log', sub { push @lines, @_ }, sub { push @lines, "E:@_" } ); [ $rs, @lines ] }
}

my $real = \&iMSCP::Execute::execute;

{
    my $exec = stub_execute(
        qr/^echo hi$/          => [ 0, 'stubbed', '' ],
        qr{^ls -l /nowhere$}   => [ 2, '', 'No such file' ],
        qr/^tail log$/         => [ 0, "one\ntwo", 'oops' ],
    );

    is_deeply( Caller::string(), [ 0, 'stubbed', '' ], 'an imported execute() is answered by the rule' );
    is_deeply( Caller::list(), [ 2, '', 'No such file' ], 'an array command matches as its joined line' );
    is_deeply( Caller::nowait(), [ 0, "one\n", "two\n", "E:oops\n" ], 'executeNoWait() feeds the output to the callbacks, line by line' );
    is_deeply( [ $exec->commands ], [ 'echo hi', 'ls -l /nowhere', 'tail log' ], 'every command is recorded' );

    eval q{ package Later; use iMSCP::Execute; 1 } or die $@;
    is( Later::execute( 'echo hi', \my $out ), 0, 'a module that imports execute() after stubbing gets the stub' );
}

is( \&Caller::execute, $real, 'the real execute() is back in the importing module' );
is( \&Later::execute, $real, 'and in a module that imported the stub' );
is( Caller::string()->[1], 'hi', 'and really runs' );

{
    my @failed;
    my $fail = stub_method( 'Test::More', 'fail', sub { push @failed, $_[0]; 0 } );
    my $exec = stub_execute( qr/^never$/ => [ 0 ] );
    my $result = Caller::string();
    undef $fail;
    is( $result->[0], 1, 'a command no rule matches returns 1' );
    is_deeply( \@failed, [ 'unexpected command: echo hi' ], 'and fails the test' );
}

{
    my $exec = stub_execute( qr/^ls/ => sub { my ( $command ) = @_; [ ref $command eq 'ARRAY' ? 0 : 9, 'array', '' ] } );
    is_deeply( Caller::list(), [ 0, 'array', '' ], 'a reply sub gets the command as it was given' );
}

like( ( eval { stub_execute(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub-Execute.t`

Expected: FAIL with `Can't locate iMSCPTest/Stub/Execute.pm`.

- [ ] **Step 3: Write the stub**

Create `test/perl/lib/iMSCPTest/Stub/Execute.pm`:

```perl
package iMSCPTest::Stub::Execute;

# Every command the code under test runs through iMSCP::Execute is answered by
# the test instead of the shell.
#
#   my $exec = stub_execute(
#       qr/^named-checkconf\b/ => [ 0, '', '' ],                 # exit, stdout, stderr
#       qr/^systemctl reload/  => sub { my ( $command ) = @_; [ 0, '', '' ] },
#   );
#   ...
#   is_deeply [ $exec->commands ], [ ... ];
#
# A command no rule matches fails the test and returns 1. `use iMSCP::Execute`
# copies execute() into each module that imports it, so every copy is
# replaced, not only the original.

use strict;
use warnings;
use Carp qw/ croak /;
use Scalar::Util ();
use Test::More ();
use iMSCP::Execute ();
use iMSCPTest::Guard;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_execute /;

sub stub_execute
{
    my ( @rules ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_execute' );
    @rules % 2 == 0 or croak( 'stub_execute takes qr/.../ => answer pairs' );

    my @calls;
    my $answer = sub {
        my ( $command ) = @_;

        my $line = ref $command eq 'ARRAY' ? join( ' ', @{ $command } ) : $command;
        push @calls, $line;

        for ( my $i = 0; $i < @rules; $i += 2 ) {
            my ( $re, $reply ) = @rules[$i, $i + 1];
            next unless $line =~ $re;
            $reply = $reply->( $command ) if ref $reply eq 'CODE';
            my ( $exit, $stdout, $stderr ) = @{ $reply };
            return ( $exit // 0, $stdout // '', $stderr // '' );
        }

        Test::More::fail( "unexpected command: $line" );
        ( 1, '', "unexpected command: $line" );
    };

    my $execute = sub {
        my ( $command, $stdout, $stderr ) = @_;

        my ( $exit, $out, $err ) = $answer->( $command );
        ${ $stdout } = $out if ref $stdout;
        ${ $stderr } = $err if ref $stderr;
        $? = $exit << 8;
        $exit;
    };

    my $executeNoWait = sub {
        my ( $command, $onStdout, $onStderr ) = @_;

        my ( $exit, $out, $err ) = $answer->( $command );
        $onStdout //= sub { print STDOUT $_[0] };
        $onStderr //= sub { print STDERR $_[0] };
        $onStdout->( "$_\n" ) for split /\n/, $out;
        $onStderr->( "$_\n" ) for split /\n/, $err;
        $? = $exit << 8;
        $exit;
    };

    my %real = (
        execute       => \&iMSCP::Execute::execute,
        executeNoWait => \&iMSCP::Execute::executeNoWait
    );
    my %stub = ( execute => $execute, executeNoWait => $executeNoWait );
    for my $name ( keys %stub ) {
        &Scalar::Util::set_prototype( $stub{$name}, prototype $real{$name} );
        _swap( $real{$name}, $stub{$name} );
    }

    iMSCPTest::Stub::Execute::Guard->new(
        sub { _swap( $stub{$_}, $real{$_} ) for keys %stub },
        calls => \@calls
    );
}

# Point every glob in every package whose sub is $from at $to.
sub _swap
{
    my ( $from, $to ) = @_;

    no strict 'refs';
    no warnings qw/ redefine prototype /;

    my @stashes = ( 'main::' );
    my %seen;
    while ( defined( my $stash = shift @stashes ) ) {
        next if $seen{$stash}++;
        for my $key ( keys %{ $stash } ) {
            my $full = $stash eq 'main::' ? $key : "$stash$key";
            if ( $key =~ /::\z/ ) {
                push @stashes, $full unless $key eq 'main::';
                next;
            }
            my $glob = ${ $stash }{$key};
            next unless ref \$glob eq 'GLOB';
            my $code = *{ $glob }{CODE} or next;
            *{ $glob } = $to if $code == $from;
        }
    }
}

package iMSCPTest::Stub::Execute::Guard;

use parent -norequire, 'iMSCPTest::Guard';

sub commands { @{ $_[0]->{'calls'} } }

1;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub-Execute.t`

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add test/perl/lib/iMSCPTest/Stub/Execute.pm test/perl/unit/iMSCPTest-Stub-Execute.t
git commit -m "test: stub_execute(), commands answered by the test, never the shell

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: `stub_db`

**Files:**
- Create: `test/perl/lib/iMSCPTest/Stub/DB.pm`
- Test: `test/perl/unit/iMSCPTest-Stub-DB.t`

**Interfaces:**
- Consumes:
  - `iMSCPTest::Guard` and `iMSCPTest::Stub::Symbol::stub_method` (Task 3).
  - `iMSCP::Database->factory()`. Code under test calls `->getRawDb()`, `->doQuery( $key, $sql, @bind )`, `->useDatabase`, `->startTransaction`, `->endTransaction`, `->quote` and `->quoteIdentifier` on what it returns.
- Produces:
  - `iMSCPTest::Stub::DB::stub_db( qr/…/ => $rows | $count | sub { my ( $sql, @bind ) = @_; … }, … )` returns a guard with:
    - `->statements`: a list of `[ $sql, @bind ]`, with the SQL's whitespace collapsed. Transactions are recorded as `[ 'BEGIN' ]`, `[ 'COMMIT' ]` and `[ 'ROLLBACK' ]`.
    - `->dbh`: the fake handle.
  - Rows are arrays of hashes (for the hash fetches) or of arrays (for the array and column fetches). An array fetch of a single-key hash row returns its one value.
  - An unmatched statement calls `Test::More::fail( "unexpected SQL: $sql" )` and dies.

- [ ] **Step 1: Write the failing test**

Create `test/perl/unit/iMSCPTest-Stub-DB.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Stub::DB: iMSCP::Database->factory() hands out a fake adapter
# whose handle answers SQL from the test's rules and records every statement.

use strict;
use warnings;
use Test::More;
use iMSCP::Database;
use iMSCPTest::Stub::Symbol qw/ stub_method /;
use iMSCPTest::Stub::DB qw/ stub_db /;

my $realFactory = \&iMSCP::Database::factory;

{
    my $db = stub_db(
        qr/^SELECT domain_id, domain_name FROM domain WHERE domain_id = \?$/ => [ { domain_id => 7, domain_name => 'a.test' } ],
        qr/^SELECT domain_name FROM domain$/                                => [ { domain_name => 'a.test' }, { domain_name => 'b.test' } ],
        qr/^SELECT COUNT\(\*\) FROM subdomain/                              => [ [ 3 ] ],
        qr/^UPDATE domain SET domain_status = \?/                           => 1,
        qr/^SELECT \* FROM php_ini/                                         => sub { my ( $sql, @bind ) = @_; [ { id => $bind[0] } ] },
    );
    my $dbh = iMSCP::Database->factory()->getRawDb();

    is_deeply(
        $dbh->selectrow_hashref( "SELECT domain_id, domain_name\n    FROM domain WHERE domain_id = ?", undef, 7 ),
        { domain_id => 7, domain_name => 'a.test' },
        'a rule matches with the whitespace collapsed'
    );
    is_deeply( $dbh->selectcol_arrayref( 'SELECT domain_name FROM domain' ), [ 'a.test', 'b.test' ], 'a column fetch takes a one-key hash row\'s value' );
    is( scalar $dbh->selectrow_array( 'SELECT COUNT(*) FROM subdomain' ), 3, 'an array fetch takes array rows' );
    is( $dbh->do( 'UPDATE domain SET domain_status = ? WHERE domain_id = ?', undef, 'ok', 7 ), 1, 'do() returns the rows affected' );
    is_deeply( $dbh->selectall_arrayref( 'SELECT * FROM php_ini WHERE domain_id = ?', { Slice => {} }, 9 ), [ { id => 9 } ], 'a rule sub gets the bind values' );

    my $sth = $dbh->prepare( 'SELECT domain_name FROM domain' );
    $sth->execute();
    my @names;
    while ( my $row = $sth->fetchrow_hashref() ) { push @names, $row->{'domain_name'} }
    is_deeply( \@names, [ 'a.test', 'b.test' ], 'prepare/execute/fetchrow_hashref walks the rows' );

    is_deeply(
        iMSCP::Database->factory()->doQuery( 'domain_name', 'SELECT domain_name FROM domain' ),
        { 'a.test' => { domain_name => 'a.test' }, 'b.test' => { domain_name => 'b.test' } },
        'doQuery() keys the rows'
    );

    $dbh->begin_work();
    $dbh->commit();
    {
        local $dbh->{'RaiseError'} = 0;
        is( $dbh->{'RaiseError'}, 0, 'handle attributes can be localised' );
    }

    is_deeply(
        [ ( $db->statements )[3, 7, 8] ],
        [ [ 'UPDATE domain SET domain_status = ? WHERE domain_id = ?', 'ok', 7 ], [ 'BEGIN' ], [ 'COMMIT' ] ],
        'statements are recorded with their bind values, transactions too'
    );

    my @failed;
    my $fail = stub_method( 'Test::More', 'fail', sub { push @failed, $_[0]; 0 } );
    ok( !eval { $dbh->do( 'DELETE FROM admin' ); 1 }, 'a statement no rule matches dies' );
    undef $fail;
    is_deeply( \@failed, [ 'unexpected SQL: DELETE FROM admin' ], 'and fails the test' );

    @failed = ();
    $fail = stub_method( 'Test::More', 'fail', sub { push @failed, $_[0]; 0 } );
    ok( !eval { $dbh->selectrow_hashref( 'SELECT COUNT(*) FROM subdomain' ); 1 }, 'a hash fetch of array rows dies' );
    undef $fail;
    like( $failed[0], qr/hash/, 'and says why' );
}

is( \&iMSCP::Database::factory, $realFactory, 'the real factory() is back' );
like( ( eval { stub_db(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub-DB.t`

Expected: FAIL with `Can't locate iMSCPTest/Stub/DB.pm`.

- [ ] **Step 3: Write the stub**

Create `test/perl/lib/iMSCPTest/Stub/DB.pm`:

```perl
package iMSCPTest::Stub::DB;

# iMSCP::Database->factory() returns a fake adapter whose raw handle answers
# SQL from the test's rules and records every statement.
#
#   my $db = stub_db(
#       qr/^SELECT .* FROM domain\b/ => [ { domain_id => 1, domain_name => 'a.test' } ],
#       qr/^UPDATE domain SET/       => 1,
#       qr/^SELECT COUNT/            => sub { my ( $sql, @bind ) = @_; [ [ 3 ] ] },
#   );
#   ...
#   is_deeply [ $db->statements ], [ [ 'UPDATE domain SET ... = ?', 'ok', 1 ] ];
#
# SQL is matched and recorded with its whitespace collapsed. A result is rows,
# as an array of hashes for the hash fetches or of arrays for the array
# fetches, or for do() the number of rows affected. A statement no rule matches
# fails the test and dies, as DBI does under RaiseError.

use strict;
use warnings;
use Carp qw/ croak /;
use Test::More ();
use iMSCP::Database ();
use iMSCPTest::Guard;
use iMSCPTest::Stub::Symbol qw/ stub_method /;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_db /;

sub stub_db
{
    my ( @rules ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_db' );
    @rules % 2 == 0 or croak( 'stub_db takes qr/.../ => result pairs' );

    my $dbh = iMSCPTest::Stub::DB::Dbh->new( \@rules );
    my $adapter = iMSCPTest::Stub::DB::Adapter->new( $dbh );
    my $factory = stub_method( 'iMSCP::Database', 'factory', sub { $adapter } );

    iMSCPTest::Stub::DB::Guard->new( sub { undef $factory }, dbh => $dbh );
}

package iMSCPTest::Stub::DB::Guard;

use parent -norequire, 'iMSCPTest::Guard';

sub dbh { $_[0]->{'dbh'} }
sub statements { @{ $_[0]->{'dbh'}->{'_statements'} } }

package iMSCPTest::Stub::DB::Adapter;

sub new
{
    my ( $class, $dbh ) = @_;
    bless { dbh => $dbh, db => { DATABASE_NAME => 'imscp' } }, $class;
}

sub getRawDb { $_[0]->{'dbh'} }

sub doQuery
{
    my ( $self, $key, $sql, @bind ) = @_;

    my $rows = $self->{'dbh'}->_rows( $sql, @bind );
    +{ map { my $row = iMSCPTest::Stub::DB::Dbh::_hash( $_, $sql ); ( $row->{$key} => $row ) } @{ $rows } };
}

sub useDatabase
{
    my ( $self, $name ) = @_;

    my $old = $self->{'db'}->{'DATABASE_NAME'};
    $self->{'db'}->{'DATABASE_NAME'} = $name;
    $old;
}

sub startTransaction { my ( $self ) = @_; $self->{'dbh'}->begin_work(); $self->{'dbh'} }
sub endTransaction { my ( $self ) = @_; $self->{'dbh'}->{'AutoCommit'} = 1; $self->{'dbh'} }
sub quote { iMSCPTest::Stub::DB::Dbh::quote( undef, $_[1] ) }
sub quoteIdentifier { iMSCPTest::Stub::DB::Dbh::quote_identifier( undef, $_[1] ) }

package iMSCPTest::Stub::DB::Dbh;

use Carp qw/ croak /;

sub new
{
    my ( $class, $rules ) = @_;

    bless {
        RaiseError   => 1,
        PrintError   => 0,
        AutoCommit   => 1,
        Driver       => { Name => 'MariaDB' },
        _rules       => $rules,
        _statements  => []
    }, $class;
}

sub _normalise
{
    my ( $sql ) = @_;

    $sql =~ s/\s+/ /g;
    $sql =~ s/^ | $//g;
    $sql;
}

sub _answer
{
    my ( $self, $sql, @bind ) = @_;

    $sql = _normalise( $sql );
    push @{ $self->{'_statements'} }, [ $sql, @bind ];

    my @rules = @{ $self->{'_rules'} };
    while ( my ( $re, $result ) = splice @rules, 0, 2 ) {
        next unless $sql =~ $re;
        return ref $result eq 'CODE' ? $result->( $sql, @bind ) : $result;
    }

    Test::More::fail( "unexpected SQL: $sql" );
    die( "unexpected SQL: $sql\n" );
}

sub _rows
{
    my ( $self, $sql, @bind ) = @_;

    my $rows = $self->_answer( $sql, @bind );
    return $rows if ref $rows eq 'ARRAY';
    Test::More::fail( "the rule for '$sql' gives no rows; a SELECT needs an array ref" );
    die( "no rows for: $sql\n" );
}

sub _hash
{
    my ( $row, $sql ) = @_;

    return $row if ref $row eq 'HASH';
    Test::More::fail( "the rows for '$sql' are arrays; this fetch needs hash rows" );
    die( "array rows for a hash fetch: $sql\n" );
}

sub _array
{
    my ( $row, $sql ) = @_;

    return $row if ref $row eq 'ARRAY';
    return [ values %{ $row } ] if ref $row eq 'HASH' && keys %{ $row } == 1;
    Test::More::fail( "the rows for '$sql' are hashes; this fetch needs array rows" );
    die( "hash rows for an array fetch: $sql\n" );
}

sub do
{
    my ( $self, $sql, undef, @bind ) = @_;

    my $result = $self->_answer( $sql, @bind );
    my $count = ref $result eq 'ARRAY' ? scalar @{ $result } : $result;
    $count || '0E0';
}

sub selectrow_hashref
{
    my ( $self, $sql, undef, @bind ) = @_;

    my $rows = $self->_rows( $sql, @bind );
    @{ $rows } ? _hash( $rows->[0], _normalise( $sql ) ) : undef;
}

sub selectrow_arrayref
{
    my ( $self, $sql, undef, @bind ) = @_;

    my $rows = $self->_rows( $sql, @bind );
    @{ $rows } ? _array( $rows->[0], _normalise( $sql ) ) : undef;
}

sub selectrow_array
{
    my ( $self, @args ) = @_;

    my $row = $self->selectrow_arrayref( @args ) or return;
    wantarray ? @{ $row } : $row->[0];
}

sub selectcol_arrayref
{
    my ( $self, $sql, undef, @bind ) = @_;

    [ map { _array( $_, _normalise( $sql ) )->[0] } @{ $self->_rows( $sql, @bind ) } ];
}

sub selectall_arrayref
{
    my ( $self, $sql, $attr, @bind ) = @_;

    my $rows = $self->_rows( $sql, @bind );
    my $hashes = ref $attr eq 'HASH' && ref $attr->{'Slice'} eq 'HASH';
    [ map { $hashes ? _hash( $_, _normalise( $sql ) ) : _array( $_, _normalise( $sql ) ) } @{ $rows } ];
}

sub selectall_hashref
{
    my ( $self, $sql, $key, undef, @bind ) = @_;

    +{ map { my $row = _hash( $_, _normalise( $sql ) ); ( $row->{$key} => $row ) } @{ $self->_rows( $sql, @bind ) } };
}

sub prepare
{
    my ( $self, $sql ) = @_;
    iMSCPTest::Stub::DB::Sth->new( $self, $sql );
}

sub begin_work { my ( $self ) = @_; push @{ $self->{'_statements'} }, [ 'BEGIN' ]; $self->{'AutoCommit'} = 0; 1 }
sub commit { my ( $self ) = @_; push @{ $self->{'_statements'} }, [ 'COMMIT' ]; $self->{'AutoCommit'} = 1; 1 }
sub rollback { my ( $self ) = @_; push @{ $self->{'_statements'} }, [ 'ROLLBACK' ]; $self->{'AutoCommit'} = 1; 1 }
sub ping { 1 }
sub err { undef }
sub errstr { '' }

sub quote
{
    my ( undef, $value ) = @_;

    return 'NULL' unless defined $value;
    ( my $quoted = $value ) =~ s/'/''/g;
    "'$quoted'";
}

sub quote_identifier
{
    my ( undef, @parts ) = @_;

    join '.', map { ( my $part = $_ ) =~ s/`/``/g; "`$part`" } grep { defined } @parts;
}

package iMSCPTest::Stub::DB::Sth;

sub new
{
    my ( $class, $dbh, $sql ) = @_;
    bless { dbh => $dbh, sql => $sql, rows => [], count => undef }, $class;
}

sub execute
{
    my ( $self, @bind ) = @_;

    my $result = $self->{'dbh'}->_answer( $self->{'sql'}, @bind );
    $self->{'rows'} = ref $result eq 'ARRAY' ? [ @{ $result } ] : [];
    $self->{'count'} = ref $result eq 'ARRAY' ? scalar @{ $result } : $result;
    $self->{'count'} || '0E0';
}

sub _sql { iMSCPTest::Stub::DB::Dbh::_normalise( $_[0]->{'sql'} ) }

sub fetchrow_hashref
{
    my ( $self ) = @_;

    my $row = shift @{ $self->{'rows'} } or return undef;
    iMSCPTest::Stub::DB::Dbh::_hash( $row, $self->_sql );
}

sub fetchrow_arrayref
{
    my ( $self ) = @_;

    my $row = shift @{ $self->{'rows'} } or return undef;
    iMSCPTest::Stub::DB::Dbh::_array( $row, $self->_sql );
}

sub fetchrow_array
{
    my ( $self ) = @_;

    my $row = $self->fetchrow_arrayref() or return;
    @{ $row };
}

sub fetchall_arrayref
{
    my ( $self, $slice ) = @_;

    my @rows = splice @{ $self->{'rows'} };
    ref $slice eq 'HASH'
        ? [ map { iMSCPTest::Stub::DB::Dbh::_hash( $_, $self->_sql ) } @rows ]
        : [ map { iMSCPTest::Stub::DB::Dbh::_array( $_, $self->_sql ) } @rows ];
}

sub fetchall_hashref
{
    my ( $self, $key ) = @_;

    +{ map { my $row = iMSCPTest::Stub::DB::Dbh::_hash( $_, $self->_sql ); ( $row->{$key} => $row ) } splice @{ $self->{'rows'} } };
}

sub rows { $_[0]->{'count'} // -1 }
sub finish { 1 }

1;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub-DB.t`

Expected: PASS, 15 tests.

- [ ] **Step 5: Commit**

```bash
git add test/perl/lib/iMSCPTest/Stub/DB.pm test/perl/unit/iMSCPTest-Stub-DB.t
git commit -m "test: stub_db(), a fake database adapter that answers from rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: config, events, sandbox and debug stubs

**Files:**
- Create: `test/perl/lib/iMSCPTest/Stub/Config.pm`
- Create: `test/perl/lib/iMSCPTest/Stub/Env.pm`
- Test: `test/perl/unit/iMSCPTest-Stub-Config.t`
- Test: `test/perl/unit/iMSCPTest-Stub-Env.t`

**Interfaces:**
- Consumes:
  - `iMSCPTest::Guard` and `stub_singleton` (Task 3).
  - `iMSCP::Debug::getMessageByType( $type, { remove => 1 } )`.
  - `iMSCP::Config`'s line format, `/^([^#\s=]+)\s*=\s*(.*)$/`.
- Produces:
  - In `iMSCPTest::Stub::Config`:
    - `repo_root()`: the checkout's absolute path.
    - `config_path( $relative )`: the path under `configs/debian/$suite/`, else under `configs/debian/default/`, else croak. The suite is `$ENV{IMSCP_TEST_SUITE}` or `trixie`.
    - `stub_config( %over )`: a guard that sets `%main::imscpConfig` from the suite's shipped `imscp.conf` plus the overrides, and restores the old contents.
    - `server_config( $server, %over )`: a hashref from `<server>/<server>.data.dist` plus the overrides.
  - In `iMSCPTest::Stub::Env`:
    - `stub_events( fail => $event | \@events )`: a guard with `->triggered` (event names, in order) and `->object` (the fake manager). It also sets the `iMSCP::EventManager` singleton.
    - `sandbox()`: the file's temp dir, created on first use and removed at exit even if permissions were taken away.
    - `sandbox_path( $absolute )`: `sandbox() . $absolute`, with its parent directory created.
    - `debug_messages( $type = 'error' )`: the messages logged since the last call.

- [ ] **Step 1: Write the failing tests**

Create `test/perl/unit/iMSCPTest-Stub-Config.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Stub::Config: the shipped configuration files, for the suite
# production runs, as the code under test would read them.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub::Config qw/ repo_root config_path stub_config server_config /;

ok( -f repo_root() . '/engine/imscp-rqst-mngr', 'repo_root() is the checkout' );
is( config_path( 'bind/parts/db.tpl' ), repo_root() . '/configs/debian/trixie/bind/parts/db.tpl', 'config_path() prefers the suite' );
is( config_path( 'cron' ), repo_root() . '/configs/debian/default/cron', 'and falls back to default' );
ok( !eval { config_path( 'no/such/file' ); 1 }, 'and dies for a file that is shipped nowhere' );

{
    local $ENV{'IMSCP_TEST_SUITE'} = 'bookworm';
    is( config_path( 'imscp.conf' ), repo_root() . '/configs/debian/bookworm/imscp.conf', 'IMSCP_TEST_SUITE picks another suite' );
}

%main::imscpConfig = ( BEFORE => 1 );
{
    my $config = stub_config( DEBUG => 1 );
    ok( exists $main::imscpConfig{'CONF_DIR'}, 'stub_config() loads the shipped imscp.conf' );
    is( $main::imscpConfig{'DEBUG'}, 1, 'with the overrides on top' );
    ok( !exists $main::imscpConfig{'BEFORE'}, 'and nothing left from before' );
}
is_deeply( \%main::imscpConfig, { BEFORE => 1 }, 'the old configuration comes back' );

my $bind = server_config( 'bind', BIND_MODE => 'master' );
is( $bind->{'BIND_DB_MASTER_DIR'}, '/var/cache/bind/imscp/master', 'server_config() reads the server\'s .data.dist' );
is( $bind->{'BIND_MODE'}, 'master', 'with the overrides on top' );

like( ( eval { stub_config(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
```

Create `test/perl/unit/iMSCPTest-Stub-Env.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Stub::Env: events, a sandbox for files, and the error log.

use strict;
use warnings;
use Test::More;
use iMSCP::Debug qw/ error /;
use iMSCP::EventManager;
use iMSCPTest::Stub::Env qw/ stub_events sandbox sandbox_path debug_messages /;

{
    my $events = stub_events( fail => 'beforeNamedAddSub' );
    my $manager = iMSCP::EventManager->getInstance();
    is( $manager, $events->object, 'stub_events() is what getInstance() returns' );
    is( $manager->trigger( 'beforeNamedAddDmn', { x => 1 } ), 0, 'an event succeeds' );
    is( $manager->trigger( 'beforeNamedAddSub' ), 1, 'unless it is told to fail' );
    is( $manager->register( 'onBoot', sub { 0 } ), 0, 'listeners can be registered' );
    is_deeply( [ $events->triggered ], [ 'beforeNamedAddDmn', 'beforeNamedAddSub' ], 'triggered events are recorded in order' );
}
ok( ref( $iMSCP::EventManager::_instance // '' ) ne 'iMSCPTest::Stub::Env::Events', 'the event manager is restored' );

my $dir = sandbox();
ok( -d $dir, 'sandbox() is a directory' );
is( sandbox(), $dir, 'the same one for the whole file' );
my $path = sandbox_path( '/etc/bind/named.conf' );
is( $path, "$dir/etc/bind/named.conf", 'sandbox_path() maps a real path into it' );
ok( -d "$dir/etc/bind", 'and creates its directory' );

mkdir "$dir/locked";
chmod 0000, "$dir/locked";
pass( 'a directory without permissions is still removed at exit (checked by eye: no imscp-test-* left in TMPDIR)' );

error( 'something broke' );
like( ( debug_messages() )[0], qr/something broke/, 'debug_messages() returns logged errors' );
is_deeply( [ debug_messages() ], [], 'once' );

like( ( eval { stub_events(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub-Config.t test/perl/unit/iMSCPTest-Stub-Env.t`

Expected: FAIL with `Can't locate iMSCPTest/Stub/Config.pm` and `…/Env.pm`.

- [ ] **Step 3: Write `iMSCPTest::Stub::Config`**

Create `test/perl/lib/iMSCPTest/Stub/Config.pm`:

```perl
package iMSCPTest::Stub::Config;

# The configuration files i-MSCP ships, for the Debian release production runs
# (trixie; IMSCP_TEST_SUITE picks another), falling back to configs/debian/default.
#
#   my $config = stub_config( DEBUG => 1 );           # %main::imscpConfig
#   my $bind   = server_config( 'bind', BIND_MODE => 'master' );
#   my $tplDir = config_path( 'bind/parts' );

use strict;
use warnings;
use Carp qw/ croak /;
use Cwd qw/ abs_path /;
use File::Basename qw/ dirname /;
use iMSCPTest::Guard;
use parent 'Exporter';

our @EXPORT_OK = qw/ repo_root config_path stub_config server_config /;

# test/perl/lib/iMSCPTest/Stub/Config.pm, five levels down.
my $ROOT = abs_path( dirname( __FILE__ ) . '/../../../../..' );

sub repo_root { $ROOT }

sub config_path
{
    my ( $relative ) = @_;

    my $suite = $ENV{'IMSCP_TEST_SUITE'} || 'trixie';
    for my $dir ( "configs/debian/$suite", 'configs/debian/default' ) {
        my $path = "$ROOT/$dir/$relative";
        return $path if -e $path;
    }
    croak( "$relative is shipped neither for $suite nor in configs/debian/default" );
}

# The parse iMSCP::Config does.
sub _read
{
    my ( $path ) = @_;

    open my $fh, '<', $path or croak( "$path: $!" );
    my %config;
    while ( my $line = <$fh> ) {
        chomp $line;
        next unless $line =~ /^([^#\s=]+)\s*=\s*(.*)$/;
        $config{$1} = $2;
    }
    \%config;
}

sub stub_config
{
    my ( %over ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_config' );

    no warnings 'once';
    my %old = %main::imscpConfig;
    untie %main::imscpConfig if tied %main::imscpConfig;
    %main::imscpConfig = ( %{ _read( config_path( 'imscp.conf' ) ) }, %over );

    iMSCPTest::Guard->new( sub { %main::imscpConfig = %old } );
}

sub server_config
{
    my ( $server, %over ) = @_;

    +{ %{ _read( config_path( "$server/$server.data.dist" ) ) }, %over };
}

1;
```

- [ ] **Step 4: Write `iMSCPTest::Stub::Env`**

Create `test/perl/lib/iMSCPTest/Stub/Env.pm`:

```perl
package iMSCPTest::Stub::Env;

# What the code under test reaches for around it: the event manager, a place
# to write files, and the error log.
#
#   my $events = stub_events( fail => 'beforeNamedAddSub' );
#   my $dir    = sandbox();                        # one per test file
#   my $conf   = sandbox_path( '/etc/bind/named.conf' );
#   like( ( debug_messages() )[0], qr/.../ );

use strict;
use warnings;
use Carp qw/ croak /;
use File::Basename qw/ dirname /;
use File::Find qw/ finddepth /;
use File::Path qw/ make_path /;
use File::Temp qw/ tempdir /;
use iMSCP::Debug ();
use iMSCPTest::Guard;
use iMSCPTest::Stub::Symbol qw/ stub_singleton /;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_events sandbox sandbox_path debug_messages /;

sub stub_events
{
    my ( %opts ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_events' );

    my @fail = ref $opts{'fail'} ? @{ $opts{'fail'} } : grep { defined } $opts{'fail'};
    my $events = iMSCPTest::Stub::Env::Events->new( { map { $_ => 1 } @fail } );
    require iMSCP::EventManager;
    my $singleton = stub_singleton( 'iMSCP::EventManager', $events );

    iMSCPTest::Stub::Env::EventsGuard->new( sub { undef $singleton }, events => $events );
}

my $SANDBOX;

sub sandbox
{
    $SANDBOX //= tempdir( 'imscp-test-XXXXXX', TMPDIR => 1 );
}

sub sandbox_path
{
    my ( $real ) = @_;

    $real =~ m{^/} or croak( 'sandbox_path takes an absolute path' );
    my $path = sandbox() . $real;
    make_path( dirname( $path ) );
    $path;
}

sub debug_messages
{
    my ( $type ) = @_;

    iMSCP::Debug::getMessageByType( $type // 'error', { remove => 1 } );
}

# A failing test can leave a directory without its execute bit; give every
# directory its permissions back so that it can be removed.
END {
    if ( defined $SANDBOX && -d $SANDBOX ) {
        local $?;
        chmod 0700, $SANDBOX;
        finddepth( { no_chdir => 1, wanted => sub { chmod 0700, $_ if !-l $_ && -d _ } }, $SANDBOX );
        system( 'rm', '-rf', '--', $SANDBOX );
    }
}

package iMSCPTest::Stub::Env::EventsGuard;

use parent -norequire, 'iMSCPTest::Guard';

sub object { $_[0]->{'events'} }
sub triggered { map { $_->[0] } @{ $_[0]->{'events'}->{'triggered'} } }

package iMSCPTest::Stub::Env::Events;

sub new
{
    my ( $class, $fail ) = @_;
    bless { fail => $fail, triggered => [], registered => [] }, $class;
}

sub trigger
{
    my ( $self, $event, @params ) = @_;

    push @{ $self->{'triggered'} }, [ $event, @params ];
    $self->{'fail'}->{$event} ? 1 : 0;
}

sub register { my ( $self, $event, $listener ) = @_; push @{ $self->{'registered'} }, [ $event, $listener ]; 0 }
sub registerOne { shift->register( @_ ) }
sub unregister { 0 }
sub hasListener { 0 }
sub clearListeners { 0 }

1;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub-Config.t test/perl/unit/iMSCPTest-Stub-Env.t && ls -d ${TMPDIR:-/tmp}/imscp-test-* 2>/dev/null | wc -l`

Expected: PASS, 12 and 14 tests. The count of leftover sandboxes is `0`.

- [ ] **Step 6: Commit**

```bash
git add test/perl/lib/iMSCPTest/Stub/Config.pm test/perl/lib/iMSCPTest/Stub/Env.pm test/perl/unit/iMSCPTest-Stub-Config.t test/perl/unit/iMSCPTest-Stub-Env.t
git commit -m "test: config, events, sandbox and error-log stubs for the unit kit

Configuration comes from the shipped trixie files, falling back to
configs/debian/default, so unit tests see what production installs.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: The `iMSCPTest::Stub` façade, `new_server`, and the existing tests on the kit

**Files:**
- Create: `test/perl/lib/iMSCPTest/Stub.pm`
- Create: `test/perl/unit/iMSCPTest-Stub.t`
- Create: `test/perl/README.md`
- Move and modify: `test/perl/iMSCP-File-copyFile.t` → `test/perl/unit/iMSCP-File-copyFile.t`
- Move and modify: `test/perl/Servers-named-bind-subdomain.t` → `test/perl/unit/Servers-named-bind-subdomain.t`

**Interfaces:**
- Consumes: everything that Tasks 3, 5, 6 and 7 export.
- Produces:
  - `use iMSCPTest::Stub qw/ :all /` exports `stub_method stub_singleton stub_execute stub_db stub_config server_config config_path repo_root stub_events sandbox sandbox_path debug_messages new_server`.
  - `new_server( $class, %fields )`: loads `$class` and returns `bless { events => <the stubbed manager>, config => {}, %fields }, $class`. It croaks unless `stub_events()` is active, because the real `iMSCP::EventManager` loads listener files from `CONF_DIR`.

- [ ] **Step 1: Write the failing test**

Create `test/perl/unit/iMSCPTest-Stub.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Stub: the whole unit kit in one import, and new_server().

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub qw/ :all /;

ok( defined &$_, "exports $_" ) for qw/
    stub_method stub_singleton stub_execute stub_db stub_config server_config config_path repo_root
    stub_events sandbox sandbox_path debug_messages new_server
/;

ok( !eval { new_server( 'Servers::named::bind' ); 1 }, 'new_server() refuses without stub_events()' );
like( $@, qr/stub_events/, 'and says what is missing' );

my $events = stub_events();
my $named = new_server( 'Servers::named::bind', config => { BIND_MODE => 'master' }, wrkDir => sandbox() );
isa_ok( $named, 'Servers::named::bind' );
is( $named->{'events'}, $events->object, 'it gets the stubbed event manager' );
is( $named->{'config'}->{'BIND_MODE'}, 'master', 'and the fields it is given' );

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Stub.t`

Expected: FAIL with `Can't locate iMSCPTest/Stub.pm`.

- [ ] **Step 3: Write the façade**

Create `test/perl/lib/iMSCPTest/Stub.pm`:

```perl
package iMSCPTest::Stub;

# The unit kit in one import. See test/perl/README.md.
#
#   use iMSCPTest::Stub qw/ :all /;
#
#   my $events = stub_events();
#   my $exec   = stub_execute( qr/^named-checkzone/ => [ 0 ] );
#   my $named  = new_server( 'Servers::named::bind', config => server_config( 'bind' ) );

use strict;
use warnings;
use Carp qw/ croak /;
use iMSCPTest::Stub::Symbol qw/ stub_method stub_singleton /;
use iMSCPTest::Stub::Execute qw/ stub_execute /;
use iMSCPTest::Stub::DB qw/ stub_db /;
use iMSCPTest::Stub::Config qw/ repo_root config_path stub_config server_config /;
use iMSCPTest::Stub::Env qw/ stub_events sandbox sandbox_path debug_messages /;
use parent 'Exporter';

our @EXPORT_OK = qw/
    stub_method stub_singleton stub_execute stub_db stub_config server_config config_path repo_root
    stub_events sandbox sandbox_path debug_messages new_server
/;
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

# An instance with the fields its constructor would have set, without running
# _init(), which reads the installed server's configuration.
sub new_server
{
    my ( $class, %fields ) = @_;

    no warnings 'once';
    ref $iMSCP::EventManager::_instance eq 'iMSCPTest::Stub::Env::Events' or croak(
        'new_server() needs stub_events() first: the real event manager loads listener files'
    );

    ( my $file = "$class.pm" ) =~ s{::}{/}g;
    require $file;
    bless { events => $iMSCP::EventManager::_instance, config => {}, %fields }, $class;
}

1;
```

- [ ] **Step 4: Move the existing tests onto the kit**

Run:

```bash
git mv test/perl/iMSCP-File-copyFile.t test/perl/unit/iMSCP-File-copyFile.t
git mv test/perl/Servers-named-bind-subdomain.t test/perl/unit/Servers-named-bind-subdomain.t
```

In `test/perl/unit/iMSCP-File-copyFile.t`:
- Change the run instructions in the header to `#   test/run.sh unit`.
- Replace `use File::Temp qw/ tempdir /;` and `use File::Find qw/ finddepth /;` with `use iMSCPTest::Stub qw/ sandbox /;`. First check that `finddepth` and `tempdir` aren't used anywhere else in the file: `grep -n 'finddepth\|tempdir' test/perl/unit/iMSCP-File-copyFile.t`.
- Replace the block from `my $tmp = tempdir( 'imscp-copyfile-XXXXXX', TMPDIR => 1 );` through the closing `}` of its `END { … }` (with the comment above it) with:

```perl
my $tmp = sandbox();
```

Replace the whole of `test/perl/unit/Servers-named-bind-subdomain.t` with:

```perl
#!/usr/bin/perl

# Servers::named::bind: deleteSub() removes the block addSub() wrote.
#
#   test/run.sh unit
#
# The zone is built from the shipped db.tpl and db_sub.tpl. Events, the address
# checks and zone compilation are stubbed; everything else is the real code
# path, and no command may reach the shell.

use strict;
use warnings;
use Test::More;
use iMSCP::File;
use iMSCP::TemplateParser qw/ process /;
use iMSCPTest::Stub qw/ :all /;

my $tplDir = config_path( 'bind/parts' );
my $wrkDir = sandbox();
my $parent = 'example.test';

{
    # IPv4 documentation addresses only; avoids needing Data::Validate::IP
    package StubNet;
    sub new { bless {}, shift }
    sub getAddrVersion { 'ipv4' }
    sub isRoutableAddr { 1 }
}

my $events = stub_events();
my $exec = stub_execute();
my $net = stub_singleton( 'iMSCP::Net', StubNet->new() );

my $named = new_server(
    'Servers::named::bind',
    config  => { BIND_MODE => 'master' },
    tplDir  => $tplDir,
    wrkDir  => $wrkDir,
    serials => { $parent => 1 },
    reload  => 0
);
my $compile = stub_method( 'Servers::named::bind', '_compileZone', sub { 0 } );

sub zone
{
    iMSCP::File->new( filename => "$wrkDir/$parent.db" )->get();
}

my $zone = process(
    {
        DOMAIN_NAME => $parent,
        IP_TYPE     => 'A',
        DOMAIN_IP   => '192.0.2.1',
        TIMESTAMP   => '2026010101'
    },
    iMSCP::File->new( filename => "$tplDir/db.tpl" )->get()
);
my $file = iMSCP::File->new( filename => "$wrkDir/$parent.db" );
$file->set( $zone );
$file->save() == 0 or die "Couldn't write the test zone\n";

my %sub = (
    DOMAIN_NAME           => "sub.$parent",
    PARENT_DOMAIN_NAME    => $parent,
    DOMAIN_IP             => '192.0.2.10',
    BASE_SERVER_PUBLIC_IP => '192.0.2.1',
    MAIL_ENABLED          => 1
);
my %other = ( %sub, DOMAIN_NAME => "other.$parent", MAIL_ENABLED => 0 );

is( $named->addSub( \%sub ), 0, 'addSub succeeds' );
is( $named->addSub( \%other ), 0, 'addSub succeeds for a second subdomain' );
like(
    zone(),
    qr/^; subdomain \[sub\.example\.test\] records BEGIN$/m,
    'addSub writes the subdomain block'
);

is( $named->deleteSub( \%sub ), 0, 'deleteSub succeeds' );
my $after = zone();
unlike( $after, qr/sub\.example\.test/, 'deleteSub removes the subdomain block' );
like(
    $after,
    qr/^; subdomain \[other\.example\.test\] records BEGIN\n\$ORIGIN other\.example\.test\.\n.*?^; subdomain \[other\.example\.test\] records ENDING\n/ms,
    'deleteSub leaves the other subdomain block alone'
);
like(
    $after,
    qr/^; subdomain \[\{SUBDOMAIN_NAME\}\] records BEGIN\n; subdomain \[\{SUBDOMAIN_NAME\}\] records ENDING$/m,
    'deleteSub leaves the insertion point for the next subdomain'
);
is_deeply( [ $exec->commands ], [], 'no command reached the shell' );

done_testing();
```

- [ ] **Step 5: Write test/perl/README.md**

Create `test/perl/README.md`:

````markdown
# Engine tests

The design is in `docs/superpowers/specs/2026-10-21-engine-test-suite-design.md`.

```
test/run.sh unit [--cover] [files…]     anywhere, as anyone
test/run.sh integration [files…]        on the throwaway CI image only, as root
docker/ci/engine-test.sh [--link]       boots the CI image and runs the integration tests in it
```

## Unit tests: `unit/<Module-Path>.t`

These run the checkout's engine code with its edges stubbed. They need no root,
no network and no database, and write only under `sandbox()`. Name each file
after the module it tests: `iMSCP::File` → `unit/iMSCP-File-copyFile.t` (one
file per behaviour is fine).

`use iMSCPTest::Stub qw/ :all /` gives you:

| Stub | Replaces |
|---|---|
| `stub_execute( qr/…/ => [ exit, stdout, stderr ], … )` | every imported copy of `execute()` / `executeNoWait()`; an unmatched command fails |
| `stub_db( qr/SQL/ => rows \| count \| sub, … )` | `iMSCP::Database->factory()`; an unmatched statement fails and dies |
| `stub_singleton( Class => $obj )` | what `Class->getInstance()` returns |
| `stub_method( Class, method => sub { … } )` | one sub; load the class first |
| `stub_config( %over )` / `server_config( 'bind', %over )` / `config_path( 'bind/parts' )` | the shipped trixie configuration, falling back to `default` |
| `stub_events( fail => $event )` | the event manager; records what is triggered |
| `sandbox()` / `sandbox_path( '/etc/x' )` | the filesystem: one temp dir per test file |
| `debug_messages()` | what went to `iMSCP::Debug::error` |
| `new_server( $class, %fields )` | an instance without `_init()`; needs `stub_events()` |

Every stub returns a guard: keep it in a lexical (`my $db = stub_db( … );`) for
as long as the stub should last. When the guard goes, the stub is undone.

## Integration tests: `integration/<system>.t`

These run as root on a booted CI image (`/etc/imscp/ci-image` marks it). They
queue panel-shaped rows with `iMSCPTest::Fixture`, run the real request manager
with `iMSCPTest::Engine::run_engine()`, and check the results through the
services. Each file creates its own customer and deletes it again.

## Coverage

`test/run.sh unit --cover` writes `cover_db/html/coverage.html`. Coverage is
reported, not gated. A module is **done** when every public sub, and every
documented error return, has at least one test.

| Module | Status | Tests |
|---|---|---|
| `iMSCP::File` | partial | `unit/iMSCP-File-copyFile.t` |
| `Servers::named::bind` | partial | `unit/Servers-named-bind-subdomain.t`, `integration/named.t` |

A test that finds a bug goes in as a `TODO` test that cites an issue; the fix
goes in its own pull request, which removes the `TODO`.
````

- [ ] **Step 6: Run the whole unit suite**

Run: `test/run.sh unit`

Expected: every file passes. That is `iMSCPTest-Stub*.t` (5 files), `iMSCP-File-copyFile.t` and `Servers-named-bind-subdomain.t`. The bind test is now 8 tests, up from 7.

- [ ] **Step 7: Commit**

```bash
git add test/perl
git commit -m "test: one import for the unit kit, and the existing tests on it

The two regression tests move to test/perl/unit/ and use the kit: the
bind test reads the trixie templates and fails if a command would
reach the shell.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 9: `docker/ci/engine-test.sh`

**Files:**
- Create: `docker/ci/engine-test.sh` (mode 755)

**Interfaces:**
- Consumes:
  - `ci_boot` and `ci_failed_units` from `docker/ci/lib.sh`.
  - `test/run.sh` (Task 4).
- Produces: `docker/ci/engine-test.sh [--image <ref>] [--link] [--keep] [-- <test/run.sh args>]`.
  - The image defaults to `$IMSCP_CI_IMAGE`, else `ghcr.io/saygoweb/imscp-ci:trixie`. The run.sh arguments default to `integration`.
  - It mounts the checkout at `/var/www/imscp-git`, and exits with `test/run.sh`'s status.
  - On failure it prints systemd's failed units and the tail of the newest logs in `/var/log/imscp`.

- [ ] **Step 1: Write the script**

Create `docker/ci/engine-test.sh`:

```bash
#!/usr/bin/env bash
#
# Run the engine's integration tests on a throwaway CI image.
#
#   docker/ci/engine-test.sh [options] [-- <test/run.sh arguments>]
#
# Options:
#   --image <ref>   the CI image (default: $IMSCP_CI_IMAGE, else
#                   ghcr.io/saygoweb/imscp-ci:trixie)
#   --link          replace the image's installed engine/ with this checkout's,
#                   as docker/imscp link does: a quick loop for engine-only
#                   changes, without building an image. Configuration and
#                   templates stay as the image installed them.
#   --keep          leave the container running afterwards, for a look inside
#
# The test/run.sh arguments default to `integration`. The checkout is mounted at
# /var/www/imscp-git. CI runs this same script; see .github/workflows/test.yml
# and ci-image.yml.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMSCP_CI_IMAGE:-ghcr.io/saygoweb/imscp-ci:trixie}"
LINK=no
KEEP=no

while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --link) LINK=yes; shift ;;
        --keep) KEEP=yes; shift ;;
        --) shift; break ;;
        *) die "unknown option: $1" ;;
    esac
done
[ "$#" -gt 0 ] || set -- integration

CONTAINER="imscp-ci-engine-$$"

cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ci_failed_units "$CONTAINER"
        printf '\n--- newest engine logs\n' >&2
        docker exec "$CONTAINER" sh -c \
            'ls -t /var/log/imscp/*.log 2>/dev/null | head -3 | while read -r f; do echo "== $f"; tail -n 40 "$f"; done' >&2 || true
    fi
    if [ "$KEEP" = yes ]; then
        log "leaving $CONTAINER running: docker exec -it $CONTAINER bash"
    else
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT

ci_boot "$CONTAINER" "$IMAGE" -v "$PROJECT_ROOT:/var/www/imscp-git"

if [ "$LINK" = yes ]; then
    log "linking the checkout's engine"
    docker exec "$CONTAINER" sh -c \
        'rm -rf /var/www/imscp/engine && ln -s /var/www/imscp-git/engine /var/www/imscp/engine'
fi

log "test/run.sh $*"
docker exec -w /var/www/imscp-git "$CONTAINER" sh test/run.sh "$@"
```

Run `chmod 755 docker/ci/engine-test.sh`.

- [ ] **Step 2: Check it**

Run: `bash -n docker/ci/engine-test.sh && (shellcheck docker/ci/engine-test.sh || true) && docker/ci/engine-test.sh --bogus; echo "exit $?"`

Expected: no syntax errors and no shellcheck errors (warnings that `lib.sh`'s style already has are fine). The last command prints `engine-test.sh: unknown option: --bogus` and `exit 1`, without booting anything.

The real run, against the local image, happens in Task 10.

- [ ] **Step 3: Commit**

```bash
git add docker/ci/engine-test.sh
git commit -m "ci: engine-test.sh, the integration tests on a throwaway CI image

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 10: Integration fixtures, the engine driver, and `integration/named.t`

**Files:**
- Create: `test/perl/lib/iMSCPTest/Engine.pm`
- Create: `test/perl/lib/iMSCPTest/Fixture.pm`
- Test: `test/perl/unit/iMSCPTest-Engine.t` (status checks, against `stub_db`)
- Test: `test/perl/unit/iMSCPTest-Fixture.t` (schema-drift checks, against `stub_db`)
- Test: `test/perl/integration/named.t`

The other fixtures the spec lists (`alias`, `subalias`, `mail`, `ftp_user`, `custom_dns`, `htaccess`, `sql_db`) arrive in phase 2, each with the integration test that first needs it.

**Interfaces:**
- Consumes:
  - `stub_db` and `stub_method` (Tasks 3 and 6), for the two unit tests.
  - `docker/ci/engine-test.sh` (Task 9).
  - The local image `imscp-ci:trixie-local` (wave C1).
  - `iMSCP::Bootstrapper->getInstance()->boot( \%opts )`.
  - `Servers::named->factory()->{'config'}->{'BIND_DB_MASTER_DIR'}`. Zone files are `<BIND_DB_MASTER_DIR>/<domain>.db` (`engine/PerlLib/Servers/named/bind.pm:268`).
- Produces:
  - In `iMSCPTest::Engine`:
    - `boot_engine()`
    - `engine_dir()`
    - `dbh()`
    - `run_engine()`, which returns true if the run exited 0. It records one test either way.
    - `is_ok( $obj [, $name ] )`
    - `is_gone( $obj [, $name ] )`
  - In `iMSCPTest::Fixture`:
    - `test_name( $label )` returns `"$label-$$.test"`.
    - `reseller()` returns an admin id.
    - `customer( label => …, <domain column> => … )` returns `{ type => 'customer', name, admin_id, domain_id, rows => [ … ] }`.
    - `subdomain( $customer, $label )` returns `{ type => 'subdomain', name, subdomain_id, rows => [ … ] }`.
    - `schedule( $obj, 'todelete' | 'tochange' | 'todisable' | 'toenable' )`.
  - Each entry in `rows` is `{ table, key, status, id }`, naming the row and its status column.

- [ ] **Step 1: Write the failing unit tests**

Create `test/perl/unit/iMSCPTest-Engine.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Engine's status checks, against a stubbed database: an entity the
# engine could not process keeps its error text in its status column, and
# is_ok() must show it even when the engine itself exited 0.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub qw/ stub_db stub_method /;
use iMSCPTest::Engine qw/ is_ok is_gone /;

my $customer = {
    name => 'c-1.test',
    rows => [
        { table => 'admin', key => 'admin_id', status => 'admin_status', id => 1 },
        { table => 'domain', key => 'domain_id', status => 'domain_status', id => 2 }
    ]
};

my %status;
my $db = stub_db(
    qr/^SELECT `(\w+)` FROM `(\w+)` WHERE `\w+` = \?$/ => sub {
        my ( $sql, $id ) = @_;
        my ( $table ) = $sql =~ /FROM `(\w+)`/;
        exists $status{"$table/$id"} ? [ [ $status{"$table/$id"} ] ] : [];
    },
    qr/^SELECT COUNT\(\*\) FROM `(\w+)` WHERE `\w+` = \?$/ => sub {
        my ( $sql, $id ) = @_;
        my ( $table ) = $sql =~ /FROM `(\w+)`/;
        [ [ exists $status{"$table/$id"} ? 1 : 0 ] ];
    },
);

sub outcome
{
    my ( $check, @args ) = @_;
    my ( @ok, @diag );
    my $okStub = stub_method( 'Test::More', 'ok', sub { push @ok, $_[0] ? 1 : 0; $_[0] } );
    my $diagStub = stub_method( 'Test::More', 'diag', sub { push @diag, @_; 0 } );
    $check->( @args );
    undef $okStub;
    undef $diagStub;
    [ $ok[0], join( "\n", @diag ) ];
}

%status = ( 'admin/1' => 'ok', 'domain/2' => 'ok' );
is_deeply( outcome( \&is_ok, $customer ), [ 1, '' ], 'is_ok passes when every row is ok' );

%status = ( 'admin/1' => 'ok', 'domain/2' => "Couldn't create the zone: named-checkzone failed" );
my $result = outcome( \&is_ok, $customer );
is( $result->[0], 0, 'is_ok fails on an error status' );
like( $result->[1], qr/domain 2: Couldn't create the zone/, 'and shows the error text' );

%status = ( 'admin/1' => 'ok' );
like( outcome( \&is_ok, $customer )->[1], qr/domain 2: no row/, 'a missing row is reported as such' );

%status = ();
is_deeply( outcome( \&is_gone, $customer ), [ 1, '' ], 'is_gone passes when every row is gone' );

%status = ( 'domain/2' => 'todelete' );
$result = outcome( \&is_gone, $customer );
is( $result->[0], 0, 'is_gone fails while a row remains' );
like( $result->[1], qr/domain 2/, 'and names it' );

done_testing();
```

Create `test/perl/unit/iMSCPTest-Fixture.t`:

```perl
#!/usr/bin/perl

# iMSCPTest::Fixture checks each table it writes against the live schema, so a
# panel schema change fails loudly instead of leaving a half-made customer.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub qw/ stub_db /;
use iMSCPTest::Fixture qw/ test_name reseller /;

is( test_name( 'named' ), "named-$$.test", 'names are <label>-<pid>.test' );
ok( !eval { test_name( 'named' ); 1 }, 'and never handed out twice' );
ok( !eval { test_name( 'Bad_Label' ); 1 }, 'labels are lower-case letters, digits and dashes' );

sub columns
{
    my ( @extra ) = @_;
    [
        ( map { { Field => $_, Null => 'YES', Default => undef, Extra => '' } }
            qw/ admin_name admin_pass admin_type created_by email admin_status domain_created / ),
        { Field => 'admin_id', Null => 'NO', Default => undef, Extra => 'auto_increment' },
        @extra
    ];
}

{
    my $db = stub_db(
        qr/^SELECT admin_id FROM admin WHERE admin_name = / => [],
        qr/^SELECT admin_id FROM admin WHERE admin_type = 'admin'/ => [ [ 1 ] ],
        qr/^SHOW COLUMNS FROM `admin`$/ => columns( { Field => 'new_required', Null => 'NO', Default => undef, Extra => '' } ),
    );
    ok( !eval { reseller(); 1 }, 'a NOT NULL column without a default that the fixture does not set stops it' );
    like( $@, qr/new_required.*panel's schema/s, 'and says why' );
}

done_testing();
```

- [ ] **Step 2: Run them to verify they fail**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Engine.t test/perl/unit/iMSCPTest-Fixture.t`

Expected: FAIL with `Can't locate iMSCPTest/Engine.pm`.

- [ ] **Step 3: Write `iMSCPTest::Engine`**

Create `test/perl/lib/iMSCPTest/Engine.pm`:

```perl
package iMSCPTest::Engine;

# Drive the installed engine the way the panel does, for the integration tests.
#
#   boot_engine();                         # once per file, before any fixture
#   my $c = customer( label => 'named' );  # iMSCPTest::Fixture
#   run_engine();                          # imscp-rqst-mngr, as the daemon runs it
#   is_ok( $c );                           # every row the fixture wrote is 'ok'
#
# Only on the throwaway CI image: test/run.sh checks for it.

use strict;
use warnings;
use Test::More ();
use parent 'Exporter';

our @EXPORT_OK = qw/ boot_engine engine_dir dbh run_engine is_ok is_gone /;

sub engine_dir { $ENV{'IMSCP_ENGINE_DIR'} || '/var/www/imscp/engine' }

# No lock: imscp-rqst-mngr, run by run_engine(), takes it.
sub boot_engine
{
    require iMSCP::Bootstrapper;
    iMSCP::Bootstrapper->getInstance()->boot( {
        mode            => 'backend',
        nolock          => 1,
        norequirements  => 1,
        config_readonly => 1
    } );
}

sub dbh
{
    require iMSCP::Database;
    iMSCP::Database->factory()->getRawDb();
}

sub run_engine
{
    my $engine = engine_dir();
    my $out = `perl '$engine/imscp-rqst-mngr' --verbose 2>&1`;
    my $exit = $? >> 8;
    Test::More::ok( $exit == 0, 'imscp-rqst-mngr exits 0' ) or Test::More::diag( $out );
    $exit == 0;
}

# i-MSCP leaves the error text in the status column of whatever it could not
# process, so that is what a failure shows.
sub is_ok
{
    my ( $obj, $name ) = @_;

    my @bad;
    for my $row ( @{ $obj->{'rows'} } ) {
        my ( $status ) = dbh()->selectrow_array(
            "SELECT `$row->{'status'}` FROM `$row->{'table'}` WHERE `$row->{'key'}` = ?", undef, $row->{'id'}
        );
        push @bad, "$row->{'table'} $row->{'id'}: " . ( $status // 'no row' )
            unless defined $status && $status eq 'ok';
    }
    Test::More::ok( !@bad, $name // "$obj->{'name'} is ok" ) or Test::More::diag( join "\n", @bad );
}

sub is_gone
{
    my ( $obj, $name ) = @_;

    my @left;
    for my $row ( @{ $obj->{'rows'} } ) {
        my ( $count ) = dbh()->selectrow_array(
            "SELECT COUNT(*) FROM `$row->{'table'}` WHERE `$row->{'key'}` = ?", undef, $row->{'id'}
        );
        push @left, "$row->{'table'} $row->{'id'} is still there" if $count;
    }
    Test::More::ok( !@left, $name // "$obj->{'name'} is gone" ) or Test::More::diag( join "\n", @left );
}

1;
```

- [ ] **Step 4: Write `iMSCPTest::Fixture`**

Create `test/perl/lib/iMSCPTest/Fixture.pm`:

```perl
package iMSCPTest::Fixture;

# Panel-shaped rows for the integration tests: what the panel writes when a
# reseller adds a customer or a customer adds a subdomain, left with status
# 'toadd' for the engine. Mirrors gui/public/reseller/user_add3.php and
# gui/public/client/subdomain_add.php.
#
#   my $c = customer( label => 'named' );            # named-<pid>.test
#   my $s = subdomain( $c, 'sub' );                  # sub.named-<pid>.test
#   run_engine();
#   schedule( $_, 'todelete' ) for $s, $c;
#   run_engine();

use strict;
use warnings;
use Carp qw/ croak /;
use iMSCPTest::Engine qw/ dbh /;
use parent 'Exporter';

our @EXPORT_OK = qw/ test_name reseller customer subdomain schedule /;

my %USED;

sub test_name
{
    my ( $label ) = @_;

    defined $label && $label =~ /^[a-z0-9-]+$/ or croak(
        'test_name needs a label of lower-case letters, digits and dashes'
    );
    my $name = "$label-$$.test";
    croak( "test_name: $name is already used in this run" ) if $USED{$name}++;
    $name;
}

my %CHECKED;

# Insert a row and return its id. The first insert into each table checks the
# live schema, so that a panel schema change stops the fixture with a reason.
sub _insert
{
    my ( $table, %row ) = @_;

    unless ( $CHECKED{$table}++ ) {
        my $columns = dbh()->selectall_arrayref( "SHOW COLUMNS FROM `$table`", { Slice => {} } );
        my %have = map { $_->{'Field'} => 1 } @{ $columns };
        my @unknown = grep { !$have{$_} } sort keys %row;
        my @unset = map { $_->{'Field'} } grep {
            $_->{'Null'} eq 'NO' && !defined $_->{'Default'} && $_->{'Extra'} !~ /auto_increment/
                && !exists $row{ $_->{'Field'} }
        } @{ $columns };
        croak( "the $table table has no column @unknown: the fixture no longer matches the panel's schema" ) if @unknown;
        croak( "the fixture does not set @unset in $table, which has no default: the panel's schema has moved on" ) if @unset;
    }

    my @columns = sort keys %row;
    dbh()->do(
        sprintf(
            'INSERT INTO `%s` (%s) VALUES (%s)',
            $table, join( ', ', map { "`$_`" } @columns ), join( ', ', ( '?' ) x @columns )
        ),
        undef, @row{@columns}
    );
    ( dbh()->selectrow_array( 'SELECT LAST_INSERT_ID()' ) )[0];
}

# Customers need a reseller. One serves the whole container.
sub reseller
{
    my ( $id ) = dbh()->selectrow_array( "SELECT admin_id FROM admin WHERE admin_name = 'citest-reseller'" );
    return $id if $id;

    my ( $adminId ) = dbh()->selectrow_array(
        "SELECT admin_id FROM admin WHERE admin_type = 'admin' ORDER BY admin_id LIMIT 1"
    );
    $adminId or croak( 'there is no admin account: is i-MSCP installed?' );

    _insert(
        'admin',
        admin_name     => 'citest-reseller',
        admin_pass     => '!',
        admin_type     => 'reseller',
        created_by     => $adminId,
        email          => 'reseller@citest.test',
        domain_created => time(),
        admin_status   => 'ok'
    );
}

sub customer
{
    my ( %domain ) = @_;

    my $name = test_name( delete $domain{'label'} // 'customer' );
    my ( $ipId ) = dbh()->selectrow_array( 'SELECT ip_id FROM server_ips ORDER BY ip_id LIMIT 1' );
    $ipId or croak( 'there is no server IP' );

    my $adminId = _insert(
        'admin',
        admin_name     => $name,
        admin_pass     => '!',
        admin_type     => 'user',
        created_by     => reseller(),
        email          => "admin\@$name",
        domain_created => time(),
        admin_status   => 'toadd'
    );
    my $domainId = _insert(
        'domain',
        domain_name                   => $name,
        domain_admin_id               => $adminId,
        domain_created                => time(),
        domain_expires                => 0,
        domain_mailacc_limit          => 0,
        domain_ftpacc_limit           => 0,
        domain_traffic_limit          => 0,
        domain_sqld_limit             => 0,
        domain_sqlu_limit             => 0,
        domain_status                 => 'toadd',
        domain_alias_limit            => 0,
        domain_subd_limit             => 0,
        domain_ip_id                  => $ipId,
        domain_disk_limit             => 0,
        domain_disk_usage             => 0,
        domain_php                    => 'yes',
        domain_cgi                    => 'no',
        allowbackup                   => 'dmn|sql|mail',
        domain_dns                    => 'no',
        phpini_perm_system            => 'no',
        phpini_perm_allow_url_fopen   => 'no',
        phpini_perm_display_errors    => 'no',
        phpini_perm_disable_functions => 'no',
        phpini_perm_mail_function     => 'yes',
        domain_external_mail          => 'no',
        web_folder_protection         => 'yes',
        mail_quota                    => 0,
        url_forward                   => 'no',
        type_forward                  => undef,
        host_forward                  => 'Off',
        wildcard_alias                => 'no',
        %domain
    );
    _insert( 'php_ini', admin_id => $adminId, domain_id => $domainId, domain_type => 'dmn' );
    _insert( 'user_gui_props', user_id => $adminId, lang => 'auto', layout => 'default' );

    +{
        type      => 'customer',
        name      => $name,
        admin_id  => $adminId,
        domain_id => $domainId,
        rows      => [
            { table => 'admin', key => 'admin_id', status => 'admin_status', id => $adminId },
            { table => 'domain', key => 'domain_id', status => 'domain_status', id => $domainId }
        ]
    };
}

sub subdomain
{
    my ( $customer, $label ) = @_;

    ref $customer eq 'HASH' && $customer->{'type'} eq 'customer' or croak( 'subdomain needs a customer' );
    defined $label && $label =~ /^[a-z0-9-]+$/ or croak( 'subdomain needs a label' );

    my $id = _insert(
        'subdomain',
        domain_id                => $customer->{'domain_id'},
        subdomain_name           => $label,
        subdomain_mount          => "/$label",
        subdomain_document_root  => '/htdocs',
        subdomain_url_forward    => 'no',
        subdomain_type_forward   => undef,
        subdomain_host_forward   => 'Off',
        subdomain_wildcard_alias => 'no',
        subdomain_status         => 'toadd'
    );
    _insert( 'php_ini', admin_id => $customer->{'admin_id'}, domain_id => $id, domain_type => 'sub' );

    +{
        type         => 'subdomain',
        name         => "$label.$customer->{'name'}",
        subdomain_id => $id,
        rows         => [ { table => 'subdomain', key => 'subdomain_id', status => 'subdomain_status', id => $id } ]
    };
}

# Ask the engine to do something to an existing object on its next run, as the
# panel does: deleting a customer marks its admin and domain rows todelete.
sub schedule
{
    my ( $obj, $status ) = @_;

    grep { $status eq $_ } qw/ todelete tochange todisable toenable / or croak( "schedule: unknown status $status" );
    dbh()->do( "UPDATE `$_->{'table'}` SET `$_->{'status'}` = ? WHERE `$_->{'key'}` = ?", undef, $status, $_->{'id'} )
        for @{ $obj->{'rows'} };
}

1;
```

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `test/run.sh unit test/perl/unit/iMSCPTest-Engine.t test/perl/unit/iMSCPTest-Fixture.t`

Expected: PASS, 7 and 5 tests.

- [ ] **Step 6: Write the integration test**

Create `test/perl/integration/named.t`:

```perl
#!/usr/bin/perl

# named: a customer's domain and subdomain are served by the DNS server once
# the engine has added them, and stop being served once it has deleted them.
# Through the real request pipeline, on the CI image only:
#
#   docker/ci/engine-test.sh -- integration test/perl/integration/named.t

use strict;
use warnings;
use Net::DNS;
use Test::More;
use iMSCPTest::Engine qw/ boot_engine run_engine is_ok is_gone /;
use iMSCPTest::Fixture qw/ customer subdomain schedule /;

boot_engine();
require Servers::named;
my $zoneDir = Servers::named->factory()->{'config'}->{'BIND_DB_MASTER_DIR'};

my $resolver = Net::DNS::Resolver->new(
    nameservers => [ '127.0.0.1' ], recurse => 0, udp_timeout => 2, retry => 1
);

# The engine reloads the server as it finishes, and named loads zones in the
# background, so give it a few seconds either way.
sub a_records
{
    my ( $name ) = @_;

    my $reply = $resolver->send( $name, 'A' ) or return ();
    map { $_->address } grep { $_->type eq 'A' } $reply->answer;
}

sub eventually
{
    my ( $test ) = @_;

    for ( 1 .. 10 ) {
        return 1 if $test->();
        sleep 1;
    }
    0;
}

my $customer = customer( label => 'named' );
my $sub = subdomain( $customer, 'sub' );

run_engine() or BAIL_OUT( 'the engine could not add the customer' );
is_ok( $customer );
is_ok( $sub );
ok( -f "$zoneDir/$customer->{'name'}.db", 'the zone file is written' );

ok( eventually( sub { a_records( $customer->{'name'} ) } ), "$customer->{'name'} answers an A record" );
my @domainA = a_records( $customer->{'name'} );
ok( eventually( sub { a_records( $sub->{'name'} ) } ), "$sub->{'name'} answers an A record" );
is_deeply( [ a_records( $sub->{'name'} ) ], \@domainA, 'at the domain\'s address' );

schedule( $_, 'todelete' ) for $sub, $customer;
run_engine() or BAIL_OUT( 'the engine could not delete the customer' );
is_gone( $sub );
is_gone( $customer );
ok( !-e "$zoneDir/$customer->{'name'}.db", 'the zone file is removed' );
ok( eventually( sub { !a_records( $customer->{'name'} ) } ), 'the domain is no longer served' );

done_testing();
```

The spec asks for NXDOMAIN after the delete. With recursion off, a server that no longer holds a zone may answer REFUSED or SERVFAIL instead, depending on its recursion settings, so the test asserts the behaviour that matters: no A record any more. Leave that comment out of the test file; it belongs in the commit message.

- [ ] **Step 7: Run it on the local trixie image**

Check `cat /sys/devices/system/cpu/intel_pstate/no_turbo` prints `1`.

Run: `docker/ci/engine-test.sh --image imscp-ci:trixie-local --link -- integration`

Expected: PASS, 12 tests.

If it fails, debug before changing anything (superpowers:systematic-debugging). Rerun with `--keep` and look inside: `docker exec -it <container> bash`, `/var/log/imscp/`, `named-checkzone`, `dig @127.0.0.1 <name>`.
- If the cause is in the fixtures, fix the fixtures.
- If the cause is a bug in the engine, stop and report it. The spec says it gets its own fix PR first, because it blocks a green path.

Then rerun without `--link` (`docker/ci/engine-test.sh --image imscp-ci:trixie-local`), to check the test passes against the image's installed engine too. Expected: PASS, 12 tests.

- [ ] **Step 8: Commit**

```bash
git add test/perl/lib/iMSCPTest/Engine.pm test/perl/lib/iMSCPTest/Fixture.pm test/perl/unit/iMSCPTest-Engine.t test/perl/unit/iMSCPTest-Fixture.t test/perl/integration/named.t
git commit -m "test: integration fixtures, the engine driver and integration/named.t

The first integration test: a customer with a subdomain, queued as the
panel queues it, added and then deleted by the real imscp-rqst-mngr,
and checked through the DNS server. After the delete it asserts that
no A record is served, rather than NXDOMAIN, since a server answers
REFUSED or SERVFAIL for a zone it has dropped depending on recursion.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 11: CI workflows

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `.github/workflows/ci-image.yml` (a new step after "Smoke test", before the login and push)

**Interfaces:**
- Consumes:
  - `test/run.sh unit --cover` and `test/run.sh ci` (Task 4).
  - `docker/ci/engine-test.sh` (Task 9).
- Produces:
  - Status checks `Test / unit`, `Test / ci-scripts` and `Test / integration`.
  - The `build` job in `ci-image.yml` runs the integration tests before it pushes.

- [ ] **Step 1: Write test.yml**

Create `.github/workflows/test.yml`:

```yaml
name: Test

# The engine's tests; see test/perl/README.md.
#
#   unit         every pull request (forks included) and every push to main: the
#                checkout mounted into the published CI image, which is not
#                booted, so the tests see production's Perl and library versions
#   ci-scripts   the tests of the docker/ci scripts and test/run.sh, on the runner
#   integration  pull requests that change only tests: the published image,
#                booted, with the checkout's engine linked in. A change to the
#                engine gets its integration tests in ci-image.yml instead, on
#                the image built from it.

on:
  pull_request:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read
  packages: read

env:
  IMSCP_CI_IMAGE: ghcr.io/saygoweb/imscp-ci:trixie

jobs:
  unit:
    runs-on: ubuntu-24.04
    timeout-minutes: 20

    steps:
      - uses: actions/checkout@v7

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Pull the CI image
        run: docker pull "$IMSCP_CI_IMAGE"

      # As nobody: unit tests must not need root, and root would hide the
      # permission checks some of them make.
      - name: Unit tests
        run: |
          mkdir -p "$RUNNER_TEMP/cover"
          chmod 777 "$RUNNER_TEMP/cover"
          docker run --rm --user 65534:65534 -e HOME=/tmp -e COVER_DIR=/cover \
              --entrypoint sh -v "$PWD:/src:ro" -v "$RUNNER_TEMP/cover:/cover" -w /src \
              "$IMSCP_CI_IMAGE" test/run.sh unit --cover

      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: coverage
          path: ${{ runner.temp }}/cover/html
          if-no-files-found: ignore

  ci-scripts:
    runs-on: ubuntu-24.04
    timeout-minutes: 10

    steps:
      - uses: actions/checkout@v7
      - name: CI script tests
        run: sh test/run.sh ci

  changes:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-24.04
    outputs:
      tests-only: ${{ steps.diff.outputs.tests-only }}

    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      # Tests only: every changed file is under test/, and some of them are
      # integration tests or their kit.
      - id: diff
        run: |
          files="$(git diff --name-only "origin/${{ github.base_ref }}...HEAD")"
          printf '%s\n' "$files"
          if [ -n "$files" ] \
              && ! printf '%s\n' "$files" | grep -qv '^test/' \
              && printf '%s\n' "$files" | grep -qE '^test/(perl/(integration|lib)/|run\.sh$)'
          then
              echo "tests-only=true" >> "$GITHUB_OUTPUT"
          else
              echo "tests-only=false" >> "$GITHUB_OUTPUT"
          fi

  integration:
    needs: changes
    if: needs.changes.outputs.tests-only == 'true'
    runs-on: ubuntu-24.04
    timeout-minutes: 30

    steps:
      - uses: actions/checkout@v7

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Pull the CI image
        run: docker pull "$IMSCP_CI_IMAGE"

      - name: Integration tests
        run: docker/ci/engine-test.sh --image "$IMSCP_CI_IMAGE" --link
```

- [ ] **Step 2: Add the integration step to ci-image.yml**

In `.github/workflows/ci-image.yml`, insert after the "Smoke test" step and before `- uses: docker/login-action@v4`:

```yaml
      # The engine's integration tests, on the image just built from this
      # change, before anything is pushed: a build that fails them never
      # becomes :trixie.
      - name: Integration tests
        run: |
          set -- ${{ steps.tags.outputs.tags }}
          docker/ci/engine-test.sh --image "$1"
```

Extend the workflow's header comment with one line after the tag list:

```yaml
# Each build runs the smoke test and the engine's integration tests
# (docker/ci/engine-test.sh) before it is pushed.
```

- [ ] **Step 3: Check the workflows**

Run:

```bash
python3 -c 'import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/test.yml .github/workflows/ci-image.yml && echo yaml ok
(command -v actionlint >/dev/null && actionlint .github/workflows/test.yml .github/workflows/ci-image.yml) || echo 'actionlint not installed; YAML parse only'
```

Expected: `yaml ok`, and either actionlint passes or it reports that it isn't installed.

Then reproduce the unit job exactly, against the local image:

```bash
mkdir -p "$PWD/.tmp-cover" && chmod 777 "$PWD/.tmp-cover"
docker run --rm --user 65534:65534 -e HOME=/tmp -e COVER_DIR=/cover --entrypoint sh \
    -v "$PWD:/src:ro" -v "$PWD/.tmp-cover:/cover" -w /src imscp-ci:trixie-local test/run.sh unit --cover
ls .tmp-cover/html/coverage.html && rm -rf .tmp-cover
```

Expected: every unit test passes as `nobody`, and `coverage.html` exists.
- If `iMSCP-File-copyFile.t` fails only because it runs as `nobody` on a read-only mount, check where it writes: it must write under `sandbox()`. Fix the test, not the job.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml .github/workflows/ci-image.yml
git commit -m "ci: run the engine's unit and integration tests

Unit tests run on every pull request, forks included, inside the
published trixie image without booting it, as nobody, with a coverage
report. Integration tests run on every image build before it is
pushed, so :trixie is never a broken engine; a pull request that only
changes tests runs them on the published image instead.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 12: The plugins on the trixie image (controller, wave 7)

**Files:** none in this repository.

**Interfaces:**
- Consumes: the `:pr-<A>` image that `ci-image.yml` builds for PR A.
- Produces: a report of each plugin's result on trixie.

- [ ] **Step 1: Wait for PR A's image**

Run: `gh run list --workflow ci-image.yml --branch worktree-test-perl-layout --limit 1` until the run succeeds. Then: `docker pull ghcr.io/saygoweb/imscp-ci:pr-<A>`.

- [ ] **Step 2: Run each plugin that calls plugin-test.yml**

From `/home/cambell/src/sgw/imscp`:

```bash
IMSCP_CI_IMAGE=ghcr.io/saygoweb/imscp-ci:pr-<A> docker/ci/plugin-test.sh --no-install .. imscp-letsencrypt -- 'sh test/run.sh'
IMSCP_CI_IMAGE=ghcr.io/saygoweb/imscp-ci:pr-<A> docker/ci/plugin-test.sh .. imscp-graphql -- '<the test command from imscp-graphql/.github/workflows/test.yml>'
```

Read the `test:` and `setup:` inputs from each plugin's `.github/workflows/test.yml` and pass them exactly. Run one plugin at a time, because of the thermal limit.

Expected: both pass. A failure is a trixie incompatibility in that plugin. Report it to the user, and don't fix it here.

- [ ] **Step 3: Flag imscp-mcp**

`imscp-mcp/.github/workflows/test.yml` pins `IMSCP_CI_IMAGE: ghcr.io/saygoweb/imscp-ci:bookworm`. It will keep running on the frozen bookworm image. Tell the user, and offer a one-line PR in that repository to switch it to `:trixie`. Don't open that PR without asking.
