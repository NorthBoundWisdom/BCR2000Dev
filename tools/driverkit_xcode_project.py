#!/usr/bin/env python3
"""Generate a local Xcode experiment; never contacts Apple or activates a dext."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil

from driverkit_probe import CLASS, DRIVER_ID, ROOT, USB_ENTITLEMENT


def generate(artifacts, team, variant):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Expected a Team Identifier")
    if variant not in {"control", "override"}:
        raise ValueError("Unknown variant")
    artifacts = artifacts.resolve()
    if not artifacts.is_relative_to(ROOT / "build"):
        raise ValueError("Project and profiles must remain under ignored build/")
    driver_info = artifacts / variant / (DRIVER_ID + ".dext/Info.plist")
    if not driver_info.is_file():
        raise ValueError("Run driverkit_probe.py build first")
    root = artifacts / ("xcode-" + variant)
    root.mkdir(exist_ok=True)
    for source in ("BCRDescriptorProbe.iig", "ProbeHost.swift"):
        shutil.copyfile(ROOT / "experiments/DriverKitProbe" / source, root / source)
    shutil.copyfile(driver_info, root / "Driver-Info.plist")
    driver_entitlements = {
        "com.apple.developer.driverkit": True,
        # Apple's documented *development-only* grant. Hardware matching in the
        # personality remains restricted to VID/PID/bcdDevice, never wildcard.
        USB_ENTITLEMENT: [{"idVendor": "*"}],
    }
    (root / "Driver-Development.entitlements").write_bytes(plistlib.dumps(driver_entitlements))
    (root / "Host.entitlements").write_bytes(plistlib.dumps({"com.apple.developer.system-extension.install": True}))
    host_info = {
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleName": "BCR DriverKit Probe",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1" if variant == "control" else "2",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
    }
    (root / "Host-Info.plist").write_bytes(plistlib.dumps(host_info))

    objects = {}

    def obj(label, isa, **fields):
        key = hashlib.sha256(label.encode()).hexdigest()[:24].upper()
        if key in objects:
            raise ValueError("Duplicate project object")
        objects[key] = {"isa": isa, **fields}
        return key

    iig = obj(
        "iig",
        "PBXFileReference",
        path="BCRDescriptorProbe.iig",
        sourceTree="<group>",
        lastKnownFileType="sourcecode.iig",
    )
    swift = obj(
        "swift", "PBXFileReference", path="ProbeHost.swift", sourceTree="<group>", lastKnownFileType="sourcecode.swift"
    )
    host_product = obj(
        "hp",
        "PBXFileReference",
        path="BCRDriverKitProbe.app",
        sourceTree="BUILT_PRODUCTS_DIR",
        explicitFileType="wrapper.application",
    )
    driver_product = obj(
        "dp",
        "PBXFileReference",
        path=DRIVER_ID + ".dext",
        sourceTree="BUILT_PRODUCTS_DIR",
        explicitFileType="wrapper.driver-extension",
    )
    products = obj(
        "products", "PBXGroup", children=[host_product, driver_product], name="Products", sourceTree="<group>"
    )
    main = obj("main", "PBXGroup", children=[iig, swift, products], sourceTree="<group>")
    iig_build = obj("ib", "PBXBuildFile", fileRef=iig)
    swift_build = obj("sb", "PBXBuildFile", fileRef=swift)
    embed_build = obj("eb", "PBXBuildFile", fileRef=driver_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
    driver_sources = obj(
        "ds",
        "PBXSourcesBuildPhase",
        buildActionMask=2147483647,
        files=[iig_build],
        runOnlyForDeploymentPostprocessing=0,
    )
    host_sources = obj(
        "hs",
        "PBXSourcesBuildPhase",
        buildActionMask=2147483647,
        files=[swift_build],
        runOnlyForDeploymentPostprocessing=0,
    )
    embed = obj(
        "embed",
        "PBXCopyFilesBuildPhase",
        buildActionMask=2147483647,
        dstPath="$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions",
        dstSubfolderSpec=16,
        files=[embed_build],
        name="Embed System Extensions",
        runOnlyForDeploymentPostprocessing=0,
    )

    def configuration(name, settings):
        config = obj(name + "conf", "XCBuildConfiguration", buildSettings=settings, name="Debug")
        return obj(
            name + "list",
            "XCConfigurationList",
            buildConfigurations=[config],
            defaultConfigurationIsVisible=0,
            defaultConfigurationName="Debug",
        )

    common = {
        "DEVELOPMENT_TEAM": team,
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_IDENTITY": "Apple Development",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "COPY_PHASE_STRIP": "NO",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
    }
    dc = configuration(
        "driver",
        dict(
            common,
            SDKROOT="driverkit",
            DRIVERKIT_DEPLOYMENT_TARGET="23.0",
            PRODUCT_NAME=DRIVER_ID,
            EXECUTABLE_NAME=CLASS,
            PRODUCT_BUNDLE_IDENTIFIER=DRIVER_ID,
            INFOPLIST_FILE="Driver-Info.plist",
            CODE_SIGN_ENTITLEMENTS="Driver-Development.entitlements",
            SKIP_INSTALL="YES",
        ),
    )
    hc = configuration(
        "host",
        dict(
            common,
            SDKROOT="macosx",
            MACOSX_DEPLOYMENT_TARGET="14.0",
            SWIFT_VERSION="6.0",
            SWIFT_STRICT_CONCURRENCY="complete",
            SWIFT_TREAT_WARNINGS_AS_ERRORS="YES",
            PRODUCT_NAME="BCRDriverKitProbe",
            PRODUCT_BUNDLE_IDENTIFIER="dev.bcragentconsole.descriptorprobe",
            INFOPLIST_FILE="Host-Info.plist",
            CODE_SIGN_ENTITLEMENTS="Host.entitlements",
        ),
    )
    pc = configuration("project", {"CLANG_CXX_LANGUAGE_STANDARD": "gnu++20"})
    driver = obj(
        "driver",
        "PBXNativeTarget",
        buildConfigurationList=dc,
        buildPhases=[driver_sources],
        buildRules=[],
        dependencies=[],
        name=CLASS,
        productName=DRIVER_ID,
        productReference=driver_product,
        productType="com.apple.product-type.driver-extension",
    )
    dependency = obj("dep", "PBXTargetDependency", target=driver)
    host = obj(
        "host",
        "PBXNativeTarget",
        buildConfigurationList=hc,
        buildPhases=[host_sources, embed],
        buildRules=[],
        dependencies=[dependency],
        name="BCRDriverKitProbe",
        productName="BCRDriverKitProbe",
        productReference=host_product,
        productType="com.apple.product-type.application",
    )
    project = obj(
        "project",
        "PBXProject",
        attributes={
            "LastUpgradeCheck": "2700",
            "TargetAttributes": {
                driver: {
                    "SystemCapabilities": {
                        "com.apple.DriverKit": {"enabled": 1},
                        "com.apple.DriverKit.transport.usb": {"enabled": 1},
                    }
                },
                host: {"SystemCapabilities": {"com.apple.SystemExtension": {"enabled": 1}}},
            },
        },
        buildConfigurationList=pc,
        compatibilityVersion="Xcode 14.0",
        developmentRegion="en",
        hasScannedForEncodings=0,
        knownRegions=["en", "Base"],
        mainGroup=main,
        productRefGroup=products,
        projectDirPath="",
        projectRoot="",
        targets=[host, driver],
    )
    bundle = root / "BCRDriverKitProbe.xcodeproj"
    bundle.mkdir(exist_ok=True)
    (bundle / "project.pbxproj").write_bytes(
        plistlib.dumps(
            {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project}
        )
    )
    return bundle


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "build/driverkit-probe")
    parser.add_argument("--team", required=True)
    parser.add_argument("--variant", choices=["control", "override"], default="control")
    args = parser.parse_args()
    print(generate(args.artifacts, args.team, args.variant))
