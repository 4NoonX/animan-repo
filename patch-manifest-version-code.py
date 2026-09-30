"""Set the Android version code inside an APK, in place in its binary manifest.

fdroidserver publishes the version code it reads out of an APK, and the metadata
keys that could override it (Builds.forcevercode, VercodeOperation) only apply
to APKs built from source. Yōkai Nightly reuses the version code of the last
stable release, so without this it would never be offered an update.

Decoding and rebuilding the APK with apktool would also work, but it recompiles
every resource and needs aapt2, which is not in Debian's main archive. The
version code is a single 32 bit integer in the root element of the binary
manifest, so patching those four bytes leaves every other byte of the APK alone.

Rewriting the manifest invalidates the signature, so the caller has to sign the
result again: Android refuses to install a differently signed APK over an
existing one.

Usage: patch-manifest-version-code.py [-o OUTPUT] APK VERSION_CODE [EXPECTED]

The patched APK is written next to the original, with .apk replaced by
-patched.apk, unless -o names it. EXPECTED, when given, is the version code the
APK is expected to carry already, and the patch is refused if it carries a
different one. An existing file is never overwritten.
"""

import os
import struct
import sys
import zipfile

ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
MANIFEST_ELEMENT = "manifest"
VERSION_CODE_ATTRIBUTE = "versionCode"

RES_XML_TYPE = 0x00080003
RES_STRING_POOL_TYPE = 0x0001
RES_XML_START_ELEMENT_TYPE = 0x0102
UTF8_FLAG = 0x100

# A typed value is a size, a reserved byte, a type byte and the data itself. The
# version code is always an integer, in decimal or hexadecimal notation, and
# never a string or a resource reference, so its four data bytes can be
# overwritten directly.
TYPED_VALUE_SIZE = 8
TYPE_INT_HEX = 0x01
TYPE_INT_DEC = 0x10
INTEGER_TYPES = (TYPE_INT_HEX, TYPE_INT_DEC)

ATTRIBUTE_SIZE = 20

# A string reference of 0xFFFFFFFF means "no string": the attribute carries no
# namespace, which is how the manifest declares its own package and its
# android:versionName, so it has to be read as a value rather than as an index.
NO_INDEX = 0xFFFFFFFF

MAX_VERSION_CODE = 2147483647

# What a v1 signature consists of. The signature is dead once the manifest has
# been rewritten and apksigner writes its own, so these are dropped rather than
# left in place for some other tool to trip over.
SIGNATURE_SUFFIXES = (".MF", ".SF", ".RSA", ".DSA", ".EC", ".SIG")
SIGNATURE_DIR = "META-INF/"


def fail(message):
    print("error: %s" % message, file=sys.stderr)
    sys.exit(1)


def is_signature(name):
    upper = name.upper()
    return upper.startswith(SIGNATURE_DIR) and upper.endswith(SIGNATURE_SUFFIXES)


def read_length8(data, offset):
    """Reads a length of one or two bytes, as the utf-8 string pool encodes it."""
    length = data[offset]
    if not length & 0x80:
        return (length, offset + 1)
    return (((length & 0x7F) << 8) | data[offset + 1], offset + 2)


def read_length16(data, offset):
    """Reads a length of one or two 16 bit words, as utf-16 pools encode it."""
    length = struct.unpack_from("<H", data, offset)[0]
    if not length & 0x8000:
        return (length, offset + 2)
    following = struct.unpack_from("<H", data, offset + 2)[0]
    return (((length & 0x7FFF) << 16) | following, offset + 4)


def read_string(data, offset, utf8):
    """Reads one string out of a string pool chunk."""
    if utf8:
        _, offset = read_length8(data, offset)
        length, offset = read_length8(data, offset)
        return data[offset:offset + length].decode("utf-8")

    length, offset = read_length16(data, offset)
    return data[offset:offset + 2 * length].decode("utf-16-le")


def read_pool(data, offset):
    """Reads a string pool chunk into a list of strings."""
    header_size = struct.unpack_from("<H", data, offset + 2)[0]
    count, style_count, flags, strings_start = struct.unpack_from("<IIII", data, offset + 8)
    if style_count:
        fail("the string pool declares styles, which no manifest has")
    if offset + strings_start > len(data):
        fail("the string pool points past the end of the manifest")

    utf8 = bool(flags & UTF8_FLAG)
    strings = []
    for index in range(count):
        entry_offset = offset + strings_start + struct.unpack_from(
            "<I", data, offset + header_size + 4 * index
        )[0]
        if entry_offset >= len(data):
            fail("string %d of the pool points past the end of the manifest" % index)
        strings.append(read_string(data, entry_offset, utf8))

    return strings


def find_version_code(manifest):
    """Returns the offset and current value of the manifest's version code."""
    if struct.unpack_from("<I", manifest, 0)[0] != RES_XML_TYPE:
        fail("this is not a binary XML manifest")

    strings = None
    offset = 8
    while offset + 8 <= len(manifest):
        chunk_type, header_size, size = struct.unpack_from("<HHI", manifest, offset)
        if size < 8 or offset + size > len(manifest):
            fail("the manifest has a malformed chunk at offset %d" % offset)

        if chunk_type == RES_STRING_POOL_TYPE:
            strings = read_pool(manifest, offset)
        elif chunk_type == RES_XML_START_ELEMENT_TYPE:
            if strings is None:
                fail("the manifest has an element before its string pool")
            found = read_version_code(manifest, offset, header_size, strings)
            if found is not None:
                return found

        offset += size

    return None


def read_version_code(manifest, offset, header_size, strings):
    """Returns the offset and value of the root element's version code."""
    # The chunk header is followed by the line number and the comment, and the
    # element's namespace and name come after those.
    namespace, name = struct.unpack_from("<II", manifest, offset + header_size)
    if name >= len(strings):
        fail("an element of the manifest points outside the string pool")
    if strings[name] != MANIFEST_ELEMENT:
        return None

    attribute_start, attribute_size, attribute_count = struct.unpack_from(
        "<HHH", manifest, offset + header_size + 8
    )
    if attribute_size < ATTRIBUTE_SIZE:
        fail("the manifest has an attribute of %d bytes, which is too small" % attribute_size)

    # The attributes start at attribute_start, counted from the start of the
    # element's attribute structure, which is the node's body, and not from the
    # start of the chunk.
    for index in range(attribute_count):
        start = offset + header_size + attribute_start + index * attribute_size
        attribute_namespace, attribute_name = struct.unpack_from("<II", manifest, start)
        if attribute_name >= len(strings):
            fail(
                "attribute %d of the manifest element points outside the string "
                "pool" % index
            )
        if strings[attribute_name] != VERSION_CODE_ATTRIBUTE:
            continue
        if (
            attribute_namespace == NO_INDEX
            or attribute_namespace >= len(strings)
            or strings[attribute_namespace] != ANDROID_NAMESPACE
        ):
            fail("the version code is not in the Android namespace")

        size, reserved, data_type = struct.unpack_from("<HBB", manifest, start + 12)
        if size != TYPED_VALUE_SIZE or reserved != 0:
            fail("the version code has a typed value of %d bytes" % size)
        if data_type not in INTEGER_TYPES:
            fail(
                "the version code is a value of type 0x%02x, which is not an integer"
                % data_type
            )
        return (start + 16, struct.unpack_from("<I", manifest, start + 16)[0])

    fail("the manifest element has no version code attribute")


def patch_manifest(manifest, version_code, expected=None):
    """Returns the manifest with the root element's version code replaced."""
    # The manifest comes out of the archive as immutable bytes, so the patch is
    # written into a copy of it.
    patched = bytearray(manifest)

    found = find_version_code(patched)
    if found is None:
        fail("the manifest has no manifest element")

    offset, current = found
    if expected is not None and current != expected:
        fail(
            "the manifest declares version code %d, not the %d that was read out "
            "of the APK" % (current, expected)
        )
    if current == version_code:
        return bytes(patched)

    struct.pack_into("<I", patched, offset, version_code)

    # Read the value back out of the patched bytes rather than trusting the
    # write, because a manifest that stopped being valid would otherwise be
    # signed and published, and the index is generated from it.
    confirmed = find_version_code(patched)
    if confirmed != (offset, version_code):
        fail("the patched manifest does not read back as version code %d" % version_code)

    return bytes(patched)


def copy_entry(info):
    """Copies a zip entry so that everything but its content is preserved."""
    entry = zipfile.ZipInfo(info.filename, date_time=info.date_time)
    entry.compress_type = info.compress_type
    entry.external_attr = info.external_attr
    entry.internal_attr = info.internal_attr
    entry.create_system = info.create_system
    return entry


def patch_apk(source, target, version_code, expected=None):
    """Writes a copy of the APK with its version code patched."""
    with zipfile.ZipFile(source) as original:
        names = original.namelist()
        if "AndroidManifest.xml" not in names:
            fail("%s has no AndroidManifest.xml" % source)
        if original.testzip() is not None:
            fail("%s is a damaged archive" % source)

        # The manifest is patched before the target is created, so a refusal
        # here does not leave a half written APK behind.
        manifest = patch_manifest(
            original.read("AndroidManifest.xml"), version_code, expected
        )
        entries = []
        for info in original.infolist():
            if is_signature(info.filename):
                continue
            if info.filename == "AndroidManifest.xml":
                content = manifest
            else:
                # The entry is opened through its own ZipInfo rather than read by
                # name, because a name that appears twice in the archive would
                # otherwise give the content of the last of the two for both.
                with original.open(info) as entry:
                    content = entry.read()
            entries.append((copy_entry(info), content))

        dropped = len(names) - len(entries)

    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as patched:
        for entry, content in entries:
            patched.writestr(entry, content)

    return dropped


def usage():
    print(
        "usage: patch-manifest-version-code.py [-o OUTPUT] APK VERSION_CODE [EXPECTED]",
        file=sys.stderr,
    )


def main(argv):
    arguments = argv[1:]
    target = None
    while arguments and arguments[0] == "-o":
        if len(arguments) < 2:
            usage()
            return 1
        target = arguments[1]
        arguments = arguments[2:]

    if len(arguments) not in (2, 3):
        usage()
        return 1

    source, raw_version_code = arguments[0], arguments[1]
    if not raw_version_code.isdigit():
        fail("the version code %r is not a number" % raw_version_code)
    version_code = int(raw_version_code)
    if not 1 <= version_code <= MAX_VERSION_CODE:
        fail(
            "the version code %d is not between 1 and %d" % (version_code, MAX_VERSION_CODE)
        )

    if not os.path.isfile(source):
        fail("%s does not exist" % source)
    if target is None:
        # The name is only a default, because a caller that has to go on to align
        # and sign the result should say where it wants it rather than have this
        # script's idea of where that is be the only thing that lines up.
        if source.endswith(".apk"):
            target = source[:-4] + "-patched.apk"
        else:
            target = source + "-patched.apk"
    if os.path.exists(target):
        fail("%s already exists" % target)

    expected = int(arguments[2]) if len(arguments) == 3 else None

    dropped = patch_apk(source, target, version_code, expected)
    print(
        "%s: version code set to %d, %d stale signature entries dropped"
        % (os.path.basename(target), version_code, dropped)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
