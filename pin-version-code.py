#!/usr/bin/env python3
"""Set the version code F-Droid clients compare against for one package.

fdroidserver publishes the version code it reads out of the APK and rejects a
"VersionCode" key in an app metadata file, so an app that keeps reusing the same
version code in its manifest can only be corrected here, in the index. The APK
itself is left alone.

The index is generated, so this reads what it can rather than assuming a shape:
a package is found by its Android package name wherever fdroidserver put it, and
the version code element is matched on its name only. Anything it cannot make
sense of is reported instead of guessed at.

Usage: pin-version-code.py INDEX APP_ID VERSION_CODE
"""

import sys
import xml.etree.ElementTree as ElementTree

# An F-Droid index keys an app on its Android package name. The v1 XML index
# carries it in a "name" child element, but it has moved between attributes and
# elements over the years, so every place it has been seen is tried.
ID_ATTRIBUTES = ("name", "id")
ID_ELEMENTS = ("packageName", "name")

VERSION_CODE_TAG = "versioncode"


def fail(message):
    print("error: " + message, file=sys.stderr)
    return 1


def text_of(element):
    return (element.text or "").strip()


def find_package(root, app_id):
    """Return the <package> element of an app, or None."""
    packages = list(root.iter("package"))

    for attribute in ID_ATTRIBUTES:
        for package in packages:
            if package.get(attribute) == app_id:
                return package

    for tag in ID_ELEMENTS:
        for package in packages:
            for child in package:
                if child.tag == tag and text_of(child) == app_id:
                    return package

    return None


def find_version_code(package):
    for child in package:
        if child.tag.lower() == VERSION_CODE_TAG:
            return child
    return None


def package_key(package):
    """The best guess at a package's Android package name, for error messages."""
    for attribute in ID_ATTRIBUTES:
        if package.get(attribute):
            return package.get(attribute)
    for tag in ID_ELEMENTS:
        for child in package:
            if child.tag == tag and text_of(child):
                return text_of(child)
    return "(no package name)"


def describe(element):
    """The attributes and child element names of an element, for error messages.

    The index is generated, so the only way to know what it looks like is to be
    told, and a package that cannot be found is exactly when that is needed.
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

    package = find_package(tree.getroot(), app_id)
    if package is None:
        # Say what the index actually holds. A package that has gone missing
        # is either a typo in the package name or an index that changed
        # shape, and "could not find it" on its own does not tell those apart.
        packages = list(tree.getroot().iter("package"))
        if not packages:
            children = sorted({child.tag for child in tree.getroot()})
            return fail(
                "%s has no <package> element, its top level elements are: %s"
                % (index, ", ".join(children) or "(none)")
            )
        return fail(
            "could not find %s in %s, which holds: %s"
            % (app_id, index, ", ".join(package_key(each) for each in packages))
            + "\nthe first one looks like: "
            + describe(packages[0])
        )

    element = find_version_code(package)
    if element is None:
        return fail(
            "%s has no <%s> element in %s, it holds: %s"
            % (app_id, VERSION_CODE_TAG, index, describe(package))
        )

    current = element.text
    if current == version_code:
        return 0

    element.text = version_code
    tree.write(index, encoding="utf-8", xml_declaration=True)
    print(
        "%s: index version code corrected from %s to %s" % (app_id, current, version_code)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
