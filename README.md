# Yōkai F-Droid repository

The [F-Droid](https://f-droid.org/) repository for
[Yōkai](https://github.com/null2264/yokai) and its nightly builds. Both
packages are rebuilt automatically from the upstream GitHub releases, so
everything here is the upstream build, only re-signed with this
repository's key so that F-Droid clients accept it.

## How to use

Copy the link below and add it to your F-Droid client:

```
https://4noonx.github.io/animan-repo/fdroid/repo?fingerprint=39C5BECE58236804C9A36D1FBED439DD89796FBD7B5D782C904E41B19DFFCADB
```

Add it to your F-Droid client, then install Yōkai and/or Yōkai Nightly from it.

| App | Package | Upstream |
| --- | --- | --- |
| Yōkai | `eu.kanade.tachiyomi.yokai` | [null2264/yokai](https://github.com/null2264/yokai/releases) |
| Yōkai Nightly | `eu.kanade.tachiyomi.nightlyYokai` | [null2264/yokai-nightly](https://github.com/null2264/yokai-nightly/releases) |

The two can be installed at the same time because upstream gives the nightly
its own package name. They do not share a database, so a library built up in
one is not visible in the other.

## Things worth knowing

- **Only the universal build is published.** Upstream also builds per-ABI
  APKs, those stay on the upstream releases page.
- **The nightly version code is rewritten in the index.** Upstream keeps the
  Android version code of every nightly at the version code of the last stable
  release, so F-Droid would never see a new build. F-Droid clients compare the
  version code in `index.xml`, so `update.sh` sets the version code published
  for the nightlies to the number in the release tag, which upstream builds as
  `r<number of commits>` and which only ever grows. The APK itself is left
  alone, so the app details in a client still show upstream's `162`.
- **Nothing about the APK is modified** other than the signature. The stable
  and the nightly APKs are upstream's `standard` flavour, which means they
  contain the proprietary Firebase and Google Play services libraries. Both
  apps are therefore tagged with the `GooglePlay` anti-feature, and with
  `NonFreeNet` because the sources the app connects to are chosen by the user
  and many of them are not free services.
- **Extensions are not part of this repository.** They are downloaded from
  the extension repository built into the app, and each one decides which site
  the app talks to.
- **Yōkai hosts no content.** The developer has no affiliation with any
  content provider, and it is your responsibility to make sure using the app
  is legal where you are.

## How this repository works

```
.github/workflows/github.yml   builds and deploys the repository to gh-pages
config.yml                     F-Droid server configuration, minus the secrets
update.sh                      downloads the releases and regenerates the metadata
fdroid/metadata/*.yml          per app metadata, descriptions, names, trackers
fdroid/repo/                   generated: APKs, icons and screenshots
```

`update.sh` runs every day and on every change to the metadata:

1. reads `releases/latest` of `null2264/yokai` and `null2264/yokai-nightly`,
2. downloads the universal APK of that release,
3. reads the package name, version code and version name out of the APK with
   `aapt` and refuses to continue if the package name is not the expected one,
4. updates `CurrentVersion`, `CurrentVersionCode` and the changelog in
   `fdroid/metadata`,
5. pulls the icon and the screenshots from the upstream repository,
6. runs `fdroid update`,
7. rewrites the nightly version code in `index.xml`, because fdroidserver only
   publishes the version code it reads out of the APK and has no metadata key
   to override it with.

The metadata in `fdroid/metadata` is edited by hand and committed, the script
only touches the version fields and the changelogs. That way a change to a
description is reviewed like any other change. Note that the CI only commits
the built repository to `gh-pages`, the version bumps made by `update.sh`
stay in the runner's workspace.

### Repository secrets

The workflow expects these repository secrets:

| Secret | Value |
| --- | --- |
| `KEYSTORE` | the repository keystore, base64 encoded (`base64 -w0 keystore.keystore`) |
| `KEY_ALIAS` | alias of the key inside the keystore |
| `KEY_STORE_PASSWORD` | keystore password |
| `KEY_PASSWORD` | key password |
| `KEY_DNAME` | distinguished name of the key, `CN=...,O=...` |

The keystore is deleted from the workspace before the repository is
published, so it never reaches `gh-pages`. Keep the original keystore
somewhere safe: losing it means every user has to reinstall the apps.

To create a keystore:

```bash
keytool -genkeypair -v -keystore keystore.keystore -storetype JKS \
    -alias animan -keyalg RSA -keysize 4096 -validity 10000 \
    -dname 'CN=Yokai F-Droid Repository, OU=F-Droid, O=4NoonX, C=US'
```

### Running it locally

```bash
apt-get install aapt curl dwebp fdroidserver jq xmlstarlet
cp config.yml fdroid/
printf '%s' "$KEYSTORE_BASE64" | base64 -d - > fdroid/keystore.keystore
# fill in the KEYALIAS / KEYSTORE_PASS / KEY_PASS / KEYDNAME placeholders
chmod 600 fdroid/config.yml fdroid/keystore.keystore
export TOKEN=          # optional
./update.sh            # which also runs fdroid update
```

## Disclaimer

This is an unofficial repository. It is not affiliated with, endorsed by or
reviewed by the F-Droid project, and it is not affiliated with the Yōkai
project. Yōkai itself is licensed under the Apache License 2.0.

## Licensing information

This repository is based on
[Julian's F-Droid repo](https://gitlab.com/julianfairfax/fdroid-repo), which
is in turn based on
[Brian May's](https://github.com/brianmay/fdroid-repo) and licensed under the
GNU General Public License v3.
