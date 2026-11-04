#!/usr/bin/env python3
"""Recreate the small Xcode project without requiring a project generator."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def q(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(key, body): objects.append(f'{uid(key)} = {{ {body} }};'); return uid(key)
files = sorted((root / 'App').glob('*.swift'))
refs, builds = [], []
for path in files:
    key = str(path.relative_to(root))
    refs.append(obj(key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";'))
    builds.append(obj(key+'build', f'isa = PBXBuildFile; fileRef = {uid(key)};'))
iconref = obj('icon', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; sourceTree = "<group>";')
refs.append(iconref)
iconbuild = obj('iconbuild', f'isa = PBXBuildFile; fileRef = {iconref};')
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Statement Manager.app"; sourceTree = BUILT_PRODUCTS_DIR;')
appgroup = obj('appgroup', f'isa = PBXGroup; children = ({",".join(refs)},); path = App; sourceTree = "<group>";')
products = obj('products', f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({appgroup},{products},); sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
lib = obj('lib', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = StatementCore;')
libbuild = obj('libbuild', f'isa = PBXBuildFile; productRef = {lib};')
sources = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({libbuild},); runOnlyForDeploymentPostprocessing = 0;')
resources = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({iconbuild},); runOnlyForDeploymentPostprocessing = 0;')
pconfigs, tconfigs = [], []
for name in ['Debug','Release']:
    pconfigs.append(obj('project'+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ MACOSX_DEPLOYMENT_TARGET = 14.0; ARCHS = arm64; ONLY_ACTIVE_ARCH = YES; SDKROOT = macosx; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; }};'))
    extra = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if name == 'Debug' else 'SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O";'
    tconfigs.append(obj('target'+name, f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
        PRODUCT_NAME = "Statement Manager"; PRODUCT_BUNDLE_IDENTIFIER = hk.local.StatementManager;
        GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = "Statement Manager";
        INFOPLIST_FILE = App/Info.plist; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.finance";
        INFOPLIST_KEY_NSHumanReadableCopyright = "Local statement and invoice manager";
        MARKETING_VERSION = 0.4.2; CURRENT_PROJECT_VERSION = 6;
        CODE_SIGN_ENTITLEMENTS = Config/StatementManager.entitlements; CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual; CODE_SIGN_INJECT_BASE_ENTITLEMENTS = {"YES" if name == "Debug" else "NO"}; ENABLE_HARDENED_RUNTIME = YES; ENABLE_APP_SANDBOX = YES;
        SWIFT_EMIT_LOC_STRINGS = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
        {extra}
    }};'''))
pcl = obj('pcl', f'isa = XCConfigurationList; buildConfigurations = ({",".join(pconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tcl = obj('tcl', f'isa = XCConfigurationList; buildConfigurations = ({",".join(tconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {tcl}; buildPhases = ({sources},{frameworks},{resources},); buildRules = (); dependencies = (); name = StatementManager; packageProductDependencies = ({lib},); productName = StatementManager; productReference = {product}; productType = "com.apple.product-type.application";')
# Keep Xcode's Test action on the same substantive sources as swift test.
testrefs, testbuilds = [], []
for path in sorted((root / 'Tests/StatementManagerTests').glob('*.swift')):
    key = str(path.relative_to(root))
    testrefs.append(obj(key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";'))
    testbuilds.append(obj(key+'build', f'isa = PBXBuildFile; fileRef = {uid(key)};'))
testgroup = obj('testgroup', f'isa = PBXGroup; children = ({",".join(testrefs)},); path = Tests/StatementManagerTests; sourceTree = "<group>";')
testproduct = obj('testproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = StatementManagerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
testsource = obj('testsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(testbuilds)},); runOnlyForDeploymentPostprocessing = 0;')
testlib = obj('testlibbuild', f'isa = PBXBuildFile; productRef = {lib};')
testframeworks = obj('testframeworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({testlib},); runOnlyForDeploymentPostprocessing = 0;')
testconfigs = []
for name in ['Debug', 'Release']:
    testconfigs.append(obj('tests'+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ PRODUCT_NAME = StatementManagerTests; PRODUCT_BUNDLE_IDENTIFIER = hk.local.StatementManagerTests; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks"; }};'))
testcl = obj('testcl', f'isa = XCConfigurationList; buildConfigurations = ({",".join(testconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
testtarget = obj('testtarget', f'isa = PBXNativeTarget; buildConfigurationList = {testcl}; buildPhases = ({testsource},{testframeworks},); buildRules = (); dependencies = (); name = StatementManagerTests; packageProductDependencies = ({lib},); productName = StatementManagerTests; productReference = {testproduct}; productType = "com.apple.product-type.bundle.unit-test";')
objects[:] = [item.replace(f'children = ({appgroup},{products},)', f'children = ({appgroup},{testgroup},{products},)').replace(f'children = ({product},)', f'children = ({product},{testproduct},)') for item in objects]
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hant",); mainGroup = {main}; packageReferences = ({package},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{testtarget},);')
(root / 'StatementManager.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {project}; }}\n')
(root / 'StatementManager.xcodeproj/xcshareddata/xcschemes/StatementManager.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Statement Manager.app" BlueprintName="StatementManager" ReferencedContainer="container:StatementManager.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testtarget}" BuildableName="StatementManagerTests.xctest" BlueprintName="StatementManagerTests" ReferencedContainer="container:StatementManager.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Statement Manager.app" BlueprintName="StatementManager" ReferencedContainer="container:StatementManager.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
