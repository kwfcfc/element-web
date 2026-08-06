// Crow CI workflow: publish Element Web via Direct Upload
//
// This branch tracks a specific upstream element-web tag. Instead of building
// from source, we download the prebuilt, GPG-signed release tarball from
// upstream, verify its signature, inject our own config + headers, pack it as a
// .tar.zst archive, and upload it to Hosting. To follow a newer release, bump
// `upstreamTag`.

// ---- Configuration ------------------------------------------------------
// Alpine is enough because we only need curl, GnuPG, tar, and zstd.
local ciImage = 'alpine:3.24';
local ciDeps = 'apk add --no-cache ca-certificates curl gnupg tar zstd';

// The branch on this repo that tracks the upstream tag and triggers a deploy.
local deployBranch = 'deploy';

local siteUrl = 'https://element.recursion-link.eu.org/';

// --- Upstream release we deploy. Bump this single line to track a new tag. ---
local upstreamTag = 'v1.12.25';
local releaseBase = 'https://github.com/element-hq/element-web/releases/download/' + upstreamTag;
local releaseKeyUrl = 'https://packages.element.io/element-release-key.asc';
local tarball = 'element-' + upstreamTag + '.tar.gz';   // element-v1.12.22.tar.gz
local extractedDir = 'element-' + upstreamTag;          // element-v1.12.22/
local archive = extractedDir + '.tar.zst';              // element-v1.12.22.tar.zst

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
      image: ciImage,
      commands: [
        ciDeps,
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
        // Element loads config.<host>.json first, then falls back to config.json.
        'cp "%s/%s" "%s/%s"' % [staticDir, configFile, extractedDir, configFile],
        'cp "%s/%s" "%s/config.json"' % [staticDir, configFile, extractedDir],
        // hosting reads a `_headers` file at the root of the uploaded archive.
        'cp "%s/%s" "%s/%s"' % [staticDir, headersFile, extractedDir, headersFile],
      ],
    },
    {
      name: 'publish',
      image: ciImage,
      depends_on: ['fetch-and-verify'],
      environment: {
        PAGES_PASSWORD: { from_secret: 'pages_password' },
      },
      commands: [
        ciDeps,
        // Archive the contents of the web root, not the containing directory.
        'tar -C "%s" -cf - . | zstd -3 -T0 -f -o "%s"' % [extractedDir, archive],
        ('curl -fsS --retry 3 -X PUT "%s"' % siteUrl) +
        ' -H "Authorization: Pages $PAGES_PASSWORD"' +
        ' -H "Content-Type: application/x-tar+zstd"' +
        (' --data-binary "@%s"' % archive),
      ],
    },
  ],
}
