#!/usr/bin/env python3
"""Set the version code F-Droid clients compare against for one app.

fdroidserver publishes the version code it reads out of the APK, and the
metadata keys that can change a version code (Builds.forcevercode and
VercodeOperation) only apply to APKs built from source, so there is no way to
override it for an upstream binary. Yōkai Nightly reuses the version code of the
stable release in every manifest, so without this every nightly looks like the
one before it and no client ever offers an update.

The APK is therefore left alone: it is signed by upstream, and Android refuses
to install a differently signed APK over an existing one. Only the index is
corrected, which is the number clients actually compare.

The XML index nests every APK inside its application, so the application is
found by its id and the version code lives in the build nested inside it:

    <application id="eu.kanade.tachiyomi.nightlyYokai">
      <id>eu.kanade.tachiyomi.nightlyYokai</id>
      <name>Yokai Nightly</name>
      <package>
        <versioncode>162</versioncode>
        <apkname>yokai-r6433.apk</apkname>
      </package>
    </application>

Builds are listed newest first, so the first one is the version being offered.

Usage: pin-version-code.py INDEX APP_ID VERSION_CODE
"""

import sys
import xml.etree.ElementTree as ElementTree

APPLICATION_TAG = "application"
BUILD_TAG = "package"
ID_TAG = "id"
VERSION_CODE_TAG = "versioncode"


def fail(message):
    print("error: " + message, file=sys.stderr)
    return 1


def text_of(element):
    return (element.text or "").strip()


def find_application(root, app_id):
    """Return the <application> element of an app, or None."""
    applications = list(root.iter(APPLICATION_TAG))

    for application in applications:
        if application.get("id") == app_id:
            return application

    for application in applications:
        for child in application:
            if child.tag == ID_TAG and text_of(child) == app_id:
                return application

    return None


def find_version_code(build):
    """The <versioncode> element of a build, matched on its name alone."""
    for child in build:
        if child.tag.lower() == VERSION_CODE_TAG:
            return child
    return None


def application_key(application):
    """The best guess at an application's package name, for error messages."""
    if application.get("id"):
        return application.get("id")
    for child in application:
        if child.tag == ID_TAG and text_of(child):
            return text_of(child)
    return "(no id)"


def describe(element):
    """The attributes and child element names of an element, for error messages.

    The index is generated, so the only way to know what it looks like is to be
    told, and an app that cannot be found is exactly when that is needed.
    """
    attributes = " ".join('%s="%s"' % pair for pair in element.attrib.items())
    children = ", ".join(child.tag for child in element)
    return "<%s %s> holds: %s" % (element.tag, attributes, children)


def main(argv):
    if len(argv) != 4:
        print("usage: pin-version-code.py INDEX APP_ID VERSION_CODE", file=sys.stderr)
        return 2

    index, app_id, version_code = argv[1], argv[2], argv[3]

    if not version_code.isdigit():
        return fail("%s is not a version code" % version_code)

    try:
        tree = ElementTree.parse(index)
    except OSError as error:
        return fail("could not open %s: %s" % (index, error))
    except ElementTree.ParseError as error:
        return fail("%s is not valid XML: %s" % (index, error))

    # Rewriting a namespaced index would mean guessing at the prefix, and an
    # F-Droid index has never used one.
    if tree.getroot().tag.startswith("{"):
        return fail("%s uses XML namespaces, refusing to rewrite it" % index)

    application = find_application(tree.getroot(), app_id)
    if application is None:
        # Say what the index actually holds. An app that has gone missing is
        # either a typo in the package name or an index that changed shape, and
        # "could not find it" on its own does not tell those apart.
        applications = list(tree.getroot().iter(APPLICATION_TAG))
        if not applications:
            children = sorted({child.tag for child in tree.getroot()})
            return fail(
                "%s has no <%s> element, its top level elements are: %s"
                % (index, APPLICATION_TAG, ", ".join(children) or "(none)")
            )
        return fail(
            "could not find %s in %s, which holds: %s"
            % (app_id, index, ", ".join(application_key(a) for a in applications))
            + "\nthe first one looks like: "
            + describe(applications[0])
        )

    builds = application.findall(BUILD_TAG)
    if not builds:
        return fail(
            "%s has no <%s> build in %s, it holds: %s"
            % (app_id, BUILD_TAG, index, describe(application))
        )

    build = builds[0]
    element = find_version_code(build)
    if element is None:
        return fail(
            "%s has no <%s> element in %s, it holds: %s"
            % (app_id, VERSION_CODE_TAG, index, describe(build))
        )

    current = element.text
    if current == version_code:
        return 0

    element.text = version_code
    tree.write(index, encoding="utf-8", xml_declaration=True)
    print(
        "%s: index version code corrected from %s to %s"
        % (app_id, current, version_code)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
