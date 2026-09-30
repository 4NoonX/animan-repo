#!/usr/bin/env python3
"""Set the version code F-Droid clients compare against for one package.

fdroidserver publishes the version code it reads out of the APK and rejects a
"VersionCode" key in an app metadata file, so an app that keeps reusing the same
version code in its manifest can only be corrected here, in the index. The APK
itself is left alone.

Usage: pin-version-code.py INDEX APP_ID VERSION_CODE
"""

import sys
import xml.etree.ElementTree as ElementTree


def fail(message):
    print("error: " + message, file=sys.stderr)
    return 1


def find_package(root, app_id):
    """Return the <package> element of an app, or None.

    F-Droid's XML index keys an app on the "name" attribute of <package>,
    which is the Android package name, and carries the human readable name in
    a <name> child element. "id" is tried as well so an index that uses it
    instead still works.
    """
    packages = list(root.iter("package"))
    for attribute in ("name", "id"):
        for package in packages:
            if package.get(attribute) == app_id:
                return package
    return None


def package_key(package):
    return package.get("name") or package.get("id") or "(no name)"


def describe(element, limit=400):
    """A one line summary of an element, for error messages.

    The index is generated, so the only way to know what it looks like is to be
    told, and a package that cannot be found is exactly when that is needed.
    """
    parts = ["<" + element.tag]
    parts += ['%s="%s"' % pair for pair in element.attrib.items()]
    opening = " ".join(parts) + ">"
    children = "".join(
        "<%s>%s</%s>" % (child.tag, (child.text or "").strip(), child.tag)
        for child in element
    )
    rendered = opening + children + "</" + element.tag + ">"
    summary = " ".join(rendered.split())
    return summary if len(summary) <= limit else summary[:limit] + "..."


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

    element = package.find("versionCode")
    if element is None:
        return fail("%s has no versionCode element in %s" % (app_id, index))

    current = element.text
    if current == version_code:
        return 0

    element.text = version_code
    tree.write(index, encoding="utf-8", xml_declaration=True)
    print("%s: index version code corrected from %s to %s" % (app_id, current, version_code))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
