// Crow CI workflow: publish Element Web to Cloudflare Pages via Direct Upload.
//
// This branch tracks a specific upstream element-web tag. Instead of building
// from source, we download the prebuilt, GPG-signed release tarball from
// upstream, verify its signature, inject our own config + headers, and upload
// the result with wrangler. To follow a newer release, bump `upstreamTag`.
//
// One-time setup on Cloudflare (creates the Pages project; safe to run locally):
//   npx wrangler pages project create element-recursion-link --production-branch main

// ---- Configuration ------------------------------------------------------
// Full node image (buildpack-deps based) ships curl, gnupg and tar, which the
// fetch+verify step needs, plus node/npx for wrangler.
local nodeImage = 'node:24-bookworm';

// The branch on this repo that tracks the upstream tag and triggers a deploy.
local deployBranch = 'deploy';

// Cloudflare Pages project name (must already exist, see header).
local projectName = 'element-recursion-link';

// The project's "production branch" on Cloudflare. Passing this value to
// `wrangler --branch` makes the upload a *production* deployment (the live
// site) rather than a preview. It does not need to be a real git branch.
local productionBranch = 'main';

// --- Upstream release we deploy. Bump this single line to track a new tag. ---
local upstreamTag = 'v1.12.21';
local releaseBase = 'https://github.com/element-hq/element-web/releases/download/' + upstreamTag;
local releaseKeyUrl = 'https://packages.element.io/element-release-key.asc';
local tarball = 'element-' + upstreamTag + '.tar.gz';   // element-v1.12.21.tar.gz
local extractedDir = 'element-' + upstreamTag;          // element-v1.12.21/

// Our two local config files that live next to the web app.
local staticDir = "static";
local configFile = 'config.element.recursion-link.eu.org.json';
local headersFile = '_headers';

// ---- Workflow -----------------------------------------------------------
{
  // Only deploy when the tracking branch is pushed, or when a human triggers
  // the pipeline manually from the Crow UI/CLI.
  when: [
    { event: 'push', branch: deployBranch },
    { event: 'manual' },
  ],

  // Shallow clone: we only need our own config/_headers from this repo, not
  // its history, so depth=1 with no tags is enough and much faster.
  clone: [
    {
      name: 'clone',
      image: 'codefloe.com/crow-plugins/clone',
      settings: {
        depth: 1,
        tags: false,
      },
    },
  ],

  steps: [
    {
      name: 'fetch-and-verify',
      image: nodeImage,
      commands: [
        // Download the prebuilt release tarball and its detached signature.
        'curl -fsSL -o "%s" "%s/%s"' % [tarball, releaseBase, tarball],
        'curl -fsSL -o "%s.asc" "%s/%s.asc"' % [tarball, releaseBase, tarball],
        // Import Element's release signing key and verify the signature.
        // A valid signature makes gpg exit 0 (the untrusted-key warning is
        // expected and harmless); a bad/missing signature fails the step.
        'curl -fsSL "%s" | gpg --import' % releaseKeyUrl,
        'gpg --verify "%s.asc" "%s"' % [tarball, tarball],
        // Unpack -> produces the `element-vX.Y.Z/` directory we will deploy.
        'tar -xzf "%s"' % tarball,
        // Inject our deployment config + security/caching headers.
        // Element loads config.<host>.json first, then falls back to config.json
        'cp "%s/%s" "%s/%s"' % [staticDir, configFile, extractedDir, configFile],
        'cp "%s/%s" "%s/config.json"' % [staticDir, configFile, extractedDir],
        // Cloudflare Pages reads a `_headers` file at the root of the upload.
        'cp "%s/%s" "%s/%s"' % [staticDir, headersFile, extractedDir, headersFile],
      ],
    },
    {
      name: 'deploy',
      image: nodeImage,
      depends_on: ['fetch-and-verify'],
      // wrangler auto-reads these for non-interactive auth.
      environment: {
        CLOUDFLARE_API_TOKEN: { from_secret: 'cloudflare_api_token' },
        CLOUDFLARE_ACCOUNT_ID: { from_secret: 'cloudflare_account_id' },
      },
      commands: [
        // Use pnpm (via corepack) rather than npx: npm walks up to the monorepo
        // root package.json whose devEngines.packageManager is pnpm and aborts
        // with EBADDEVENGINES. pnpm satisfies that requirement.
        ('npx wrangler@4 pages deploy "%s"' % extractedDir) +
        (' --project-name "%s"' % projectName) +
        (' --branch "%s"' % productionBranch) +
        ' --commit-hash "$CI_COMMIT_SHA"' +
        ' --commit-message "$CI_COMMIT_MESSAGE"',
      ],
    },
  ],
}
