#!/bin/bash
# Compile the native support checks against the same modules shipped by the app.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
cp -R HardwareProfiles build/
sources=(
    ReYogaSMCApp/Shared/LocalizedKey.swift
    ReYogaSMCApp/Views/Controls/ControlPresentation.swift
    ReYogaSMCApp/Hardware/Controls/SavedHardwareSettings.swift
    ReYogaSMCApp/Hardware/Controls/HardwareSnapshot.swift
    ReYogaSMCApp/Hardware/Controls/HardwareFeatureStatus.swift
    ReYogaSMCApp/Hardware/Controls/HardwareCapabilities.swift
    ReYogaSMCApp/Shared/SupportError.swift
    ReYogaSMCApp/Hardware/Controls/PowerLimitInput.swift
    ReYogaSMCApp/Hardware/Profiles/HardwareProfiles.swift
    ReYogaSMCApp/Hardware/Profiles/LaptopIdentity.swift
    ReYogaSMCApp/Hardware/Lighting/SavedRGBSettings.swift
    ReYogaSMCApp/Views/Components/RGBColorConversion.swift
    ReYogaSMCApp/Hardware/Lighting/RGBMatchProfile.swift
    ReYogaSMCApp/Hardware/Lighting/LegionRGBController.swift
    ReYogaSMCApp/Hardware/Input/LegionHotkeys.swift
    ReYogaSMCApp/System/AppleScriptActions.swift
    ReYogaSMCApp/System/FanAuthorization.swift
    ReYogaSMCApp/Hardware/Sensors/SMCTemperatureReader.swift
    ReYogaSMCApp/Hardware/Sensors/BatterySnapshot.swift
    ReYogaSMCApp/Diagnostics/DiagnosticCollector.swift
    ReYogaSMCApp/Hardware/ACPI/IASLCompiler.swift
    ReYogaSMCApp/Hardware/ACPI/ACPIExport.swift
    ReYogaSMCApp/Hardware/ACPI/ThinkPadACPI.swift
    ReYogaSMCApp/Views/Components/AppTheme.swift
    ReYogaSMCApp/Shared/ReYogaConstants.swift
    ReYogaSMCApp/Hardware/Driver/IORegistryAccess.swift
    ReYogaSMCApp/Events/EventAction.swift
    ReYogaSMCApp/Hardware/Driver/DriverEventContext.swift
    ReYogaSMCApp/Events/DefaultEvents.swift
    ReYogaSMCApp/Events/EventPreferences.swift
    ReYogaSMCApp/Hardware/HardwareFeedback.swift
    ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift
    ReYogaSMCApp/Views/HUD/EventImage.swift
    ReYogaSMCApp/Views/Components/ReYogaBrand.swift
    ReYogaSMCApp/Views/HUD/StatusHUD.swift
    ReYogaSMCApp/Views/HUD/HardwareFeedbackPresenter.swift
    ReYogaSMCApp/Views/Controls/HotkeyPermissionActions.swift
    ReYogaSMCApp/Views/Components/ColorPanelPlacement.swift
    Tests/main.swift
)
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -c ReYogaSMCFanHelper/FanAuthorizationClient.m -o build/FanAuthorizationClient.o
swiftc -import-objc-header ReYogaSMCApp/Hardware/Driver/ReYogaSMC-Bridging-Header.h "${sources[@]}" build/FanAuthorizationClient.o -o build/SupportTests
REYOGA_LOCALIZATION_ROOT="$root" build/SupportTests
clang++ -std=c++14 -fsyntax-only Tests/control_validation.cpp
clang++ -std=c++14 -fsyntax-only Tests/notification_abi.cpp
clang++ -target x86_64-apple-macosx11.0 -std=c++14 -fsyntax-only -DKERNEL -DKERNEL_PRIVATE \
    -I MacKernelSDK/Headers Tests/notification_abi.cpp
