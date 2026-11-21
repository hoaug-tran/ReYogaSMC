"""Tests for Legion custom fan curve architecture, validation, and watchdog."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest
try:
    from .source_tools import kernel_sources, function
except ImportError:
    from source_tools import kernel_sources, function

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LegionFanCurveStaticTests(unittest.TestCase):
    def test_dynamic_capability_detection_without_dsdt_hashes(self):
        identity_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCIdentity.cpp').read_text(encoding='utf-8')
        fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')
        telemetry_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCTelemetry.cpp').read_text(encoding='utf-8')

        # Must use ReYogaFirmware::select and live DSDT SystemMemory proof without prefix wildcarding
        self.assertIn('ReYogaFirmware::select', identity_src)
        self.assertIn('ReYogaFirmware::hasSystemMemoryRegion', identity_src)
        self.assertIn('hasVerifiedLegionCurveProfile', fan_src)
        self.assertIn('isLegionFanCurveSupported', fan_src)
        self.assertIn('isLegionFanCurveSupported', telemetry_src)
        self.assertNotIn('strncmp(candidate->id, "legion"', identity_src)
        self.assertNotIn('strncmp(nativeProfile->id, "legion"', fan_src)

        # Must NOT hardcode DSDT hashes or rigid model strings in shared paths
        self.assertNotIn('dsdt_hash', fan_src.lower())
        self.assertNotIn('dsdt_hash', identity_src.lower())
        self.assertNotIn('82n6', fan_src.lower())

        # Published properties gated on initLegionFanControls() success
        self.assertIn('if (hasVerifiedLegionCurveProfile() && initLegionFanControls())', identity_src)
        self.assertIn('"ThinkFanProtocolVersion"', identity_src)
        self.assertIn('"ThinkFanAuthorizationVersion"', identity_src)
        self.assertIn('"ThinkFanCurveVersion"', identity_src)
        self.assertNotIn('setProperty("ThinkFanTelemetryVersion"', identity_src)
        self.assertIn('removeProperty("ThinkFanTelemetryVersion")', identity_src)
        self.assertIn('"Dual fan"', identity_src)
        self.assertIn('"Fan number"', identity_src)
        self.assertIn('"CustomFanCurve"', telemetry_src)

    def test_mmio_mapping_and_handshake_constants(self):
        fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')
        identity_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCIdentity.cpp').read_text(encoding='utf-8')
        # Must derive MMIO base/size from matched profile, never hardcode 0xFE00D400ULL
        self.assertNotIn('0xFE00D400', fan_src)
        self.assertNotIn('0xFE00D400', identity_src)
        self.assertIn('nativeProfile->ecBase', fan_src)
        self.assertIn('nativeProfile->ecSize', fan_src)
        # Change counters
        self.assertIn('0x1FE', fan_src)
        self.assertIn('0x1FF', fan_src)
        # Re-evaluation resets
        self.assertIn('0x134', fan_src)
        self.assertIn('0x234', fan_src)
        self.assertIn('0x235', fan_src)
        self.assertIn('0x236', fan_src)
        # Lock fan controller
        self.assertIn('0x0AB', fan_src)

    def test_lifecycle_deferral_and_sleep_fallback(self):
        identity_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCIdentity.cpp').read_text(encoding='utf-8')
        fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')
        vpc_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPC.cpp').read_text(encoding='utf-8')

        # initLegionFanControls must return bool and syncLegionFanCapability must run after initBridge()
        self.assertIn('bool IdeaVPC::initLegionFanControls()', fan_src)
        self.assertIn('initLegionFanControls()', identity_src)
        self.assertIn('syncLegionFanCapability()', vpc_src)

        # setPowerStateGated sleep path must restore fans to Auto
        self.assertIn('restorePlatformFansGated', vpc_src)

    def test_client_lifecycle_and_disconnection_fallback(self):
        userclient_src = (ROOT / 'ReYogaSMC/ReYogaSMCUserClient.cpp').read_text(encoding='utf-8')
        ideavpc_controls_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCControls.cpp').read_text(encoding='utf-8')
        reyogavpc_src = (ROOT / 'ReYogaSMC/ReYogaVPC.cpp').read_text(encoding='utf-8')
        ideavpc_fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')

        # UserClient closeGated must restore user controls immediately
        self.assertIn('provider_->restoreUserControls()', userclient_src)
        self.assertIn('clientClose()', userclient_src)
        self.assertIn('clientDied()', userclient_src)

        # IdeaVPC restoreUserControls must call restorePlatformFansGated
        self.assertIn('restorePlatformFansGated()', ideavpc_controls_src)

        # ReYogaVPC restoreUserControls must call restoreThinkFans which calls restorePlatformFans
        self.assertIn('restorePlatformFans()', reyogavpc_src)

        # restorePlatformFansGated must cancel both leases and reset active controls to 0x84
        self.assertIn('legionFanLease.cancel(0)', ideavpc_fan_src)
        self.assertIn('legionFanLease.cancel(1)', ideavpc_fan_src)
        self.assertIn('activeFanControl[0] = 0x84', ideavpc_fan_src)
        self.assertIn('activeFanControl[1] = 0x84', ideavpc_fan_src)

    def test_partial_lease_and_recursion_safety(self):
        fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')

        # accessLegionFanGated must check sibling lease before global restore
        self.assertIn('legionFanLease.deadline[1 - fan] != 0', fan_src)

        # restorePlatformFansGated must clear customFanCurveActive before applying table
        self.assertIn('customFanCurveActive = false;', fan_src)
        self.assertIn('applyLegionFanCurveTable(factoryCurveTable, true)', fan_src)

        # validateFanCurveTable must enforce 100 RPM granularity and upper bound <= 6000
        self.assertIn('6000', fan_src)
        self.assertIn('% 100 != 0', fan_src)

        # accessLegionFanGated must wire curve programming through applyLegionFanCurveTable and hardware readback
        gated_fn = function(fan_src, 'IOReturn IdeaVPC::accessLegionFanGated(')
        self.assertIn('applyLegionFanCurveTable(', gated_fn)
        self.assertIn('readHardwareFanControl(', gated_fn)
        self.assertIn('disengageFullSpeed()', gated_fn)

    def test_safemode_fail_closed_guard(self):
        fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')
        userclient_src = (ROOT / 'ReYogaSMC/ReYogaSMCUserClient.cpp').read_text(encoding='utf-8')

        # safeMode must disable capability, MMIO init, writes, and fan curve access
        self.assertIn('if (safeMode || !nativeProfile)', fan_src)
        self.assertIn('if (safeMode || !hasVerifiedLegionCurveProfile())', fan_src)
        self.assertIn('if (safeMode)\n        return kIOReturnUnsupported;', fan_src)
        self.assertIn('getProperty("SafeMode") == kOSBooleanTrue', fan_src)
        self.assertIn('!safeMode', fan_src)

        # UserClient dispatchGated must block non-lifecycle methods in SafeMode
        self.assertIn('self->provider_->getProperty("SafeMode") == kOSBooleanTrue', userclient_src)

    def test_stale_telemetry_and_sleep_power_state(self):
        fan_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCFan.cpp').read_text(encoding='utf-8')
        vpc_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPC.cpp').read_text(encoding='utf-8')
        controls_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCControls.cpp').read_text(encoding='utf-8')
        telemetry_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCTelemetry.cpp').read_text(encoding='utf-8')

        # Telemetry RPM >= 20000 or 0xFFFF sanitized to 0 and returns kIOReturnUnderrun
        self.assertIn('readRPM >= 20000 || readRPM == 0xFFFF', fan_src)
        self.assertIn('return kIOReturnUnderrun;', fan_src)

        # Sleep state == 0 restores fans and cancels timers
        self.assertIn('restorePlatformFansGated();', vpc_src)
        self.assertIn('legionFanWatchdog->cancelTimeout();', vpc_src)
        self.assertIn('telemetryPoller->cancelTimeout();', vpc_src)

        # Power mode change restores fans with ecReloadedCurve = true
        self.assertIn('restorePlatformFansGated(true);', controls_src)
        self.assertIn('restorePlatformFansGated(true);', telemetry_src)

    def test_app_and_helper_fan_curve_integration(self):
        driver_conn = (ROOT / 'ReYogaSMCApp/Application/DriverConnection.swift').read_text(encoding='utf-8')
        think_fan_helper = (ROOT / 'ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift').read_text(encoding='utf-8')
        cooling_page = (ROOT / 'ReYogaSMCApp/Views/Controls/CoolingControlsPage.swift').read_text(encoding='utf-8')
        hw_manager = (ROOT / 'ReYogaSMCApp/Hardware/HardwareManager.swift').read_text(encoding='utf-8')
        en_strings = (ROOT / 'en.lproj/Localizable.strings').read_text(encoding='utf-8')
        vi_strings = (ROOT / 'vi.lproj/Localizable.strings').read_text(encoding='utf-8')

        # DriverConnection generalization and deferred profile matching
        self.assertIn('["ThinkVPC", "IdeaVPC"].contains(provider)', driver_conn)
        self.assertIn('self.provider == "IdeaVPC"', driver_conn)
        self.assertIn('getNumber("ThinkFanProtocolVersion", context.service) == 1', driver_conn)
        self.assertIn('$thinkFanProtocolVersion', driver_conn)
        self.assertIn('handleDeferredThinkFanProtocol()', driver_conn)
        self.assertIn('ensureThinkWakeObserver()', driver_conn)
        idea_case = driver_conn.split('case "IdeaVPC":', 1)[1].split('case "ThinkVPC":', 1)[0]
        self.assertIn('ECCap == "RW" || ECCap == nil || provider == "IdeaVPC"', idea_case)

        # HardwareManager generalization and deferred restore check
        self.assertIn('["ThinkVPC", "IdeaVPC"].contains(providerClass) && thinkFanTelemetrySupported', hw_manager)
        self.assertIn('["ThinkVPC", "IdeaVPC"].contains(providerClass) ? props["Dual fan"]', hw_manager)
        self.assertIn('publish(\\.thinkFanProtocolVersion,', hw_manager)
        self.assertIn('props["ProfileMatchStage"] as? String) == "identity_unavailable"', hw_manager)
        self.assertIn('publish(\\.thinkFanECNeedsHelpers, providerClass == "ThinkVPC"', hw_manager)
        self.assertNotIn('["ThinkVPC", "IdeaVPC"].contains(providerClass)', hw_manager.split('thinkFanECNeedsHelpers', 1)[1].split('\n', 2)[0])

        # ThinkFanHelper 10-point Legion curve support and capability check
        self.assertIn('hasCustomFanCurveCapability', think_fan_helper)
        self.assertIn('(2...10).contains(points.count)', think_fan_helper)
        self.assertIn('legionDefaults', think_fan_helper)
        self.assertIn('resetCurveToDefaults', think_fan_helper)
        self.assertIn('Curve stopped: driver fell back to BIOS Auto.', think_fan_helper)

        # CoolingControlsPage UI controls and edit-preservation on polling
        self.assertIn('ThinkPadFanPanel(manager: manager)', cooling_page)
        self.assertIn('manager.thinkFanCurveSupported || manager.fanHelper != nil', cooling_page)
        self.assertIn('addCurvePoint()', cooling_page)
        self.assertIn('Fan Curve Fallback Active', cooling_page)
        self.assertIn('Reset (10 Points)', cooling_page)
        self.assertIn('Reset (4 Points)', cooling_page)
        self.assertNotIn('syncWithFan()', cooling_page)
        self.assertIn('syncModeFromDriver(', cooling_page)
        self.assertIn('syncCurveDraftFromHelper()', cooling_page)

        # Localization completeness
        for key in ('Custom Fan Curve', 'Fan Curve Fallback Active', 'Resume Curve', 'Add Point',
                    'Remove Point', 'Reset (4 Points)', 'Reset (10 Points)', 'CPU: %.0f °C',
                    '%d points', 'P%d:', 'Curve stopped: driver fell back to BIOS Auto.',
                    'BIOS Auto (Fallback)'):
            self.assertIn(f'"{key}"', en_strings)
            self.assertIn(f'"{key}"', vi_strings)

    def test_ideavpc_curve_policy_behaviour(self):
        helper_src = (ROOT / 'ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift').read_text(encoding='utf-8')
        has_cap_fn = function(helper_src, 'static func hasCustomFanCurveCapability(')
        unavailable_fn = function(helper_src, 'static func unavailableReason(')

        def eval_has_custom_curve(props):
            # Evaluate branches extracted from ThinkFanCurvePolicy.hasCustomFanCurveCapability
            self.assertIn('properties["CustomFanCurve"] as? Bool == true', has_cap_fn)
            if props.get('CustomFanCurve') is True:
                return True
            if 'FeatureStatus' in has_cap_fn:
                features = props.get('FeatureStatus')
                if isinstance(features, dict):
                    curve = features.get('CustomFanCurve')
                    if isinstance(curve, dict) and curve.get('Available') is True:
                        return True
            return False

        def swift_prop(props, key, kind):
            val = props.get(key)
            if kind == 'String':
                return val if isinstance(val, str) else None
            if kind == 'Bool':
                return val if isinstance(val, bool) else None
            if kind == 'Int':
                return val if (type(val) is int) else None
            return val

        def eval_unavailable_reason(props):
            guards = re.findall(
                r'guard\s+([\s\S]*?)\s+else\s*\{\s*return\s+"([^"\n]+)"\s*\}',
                unavailable_fn,
            )
            self.assertGreaterEqual(len(guards), 7)
            env = {'ioClass': None}
            for cond, message in guards:
                cond = ' '.join(cond.split())
                let_match = re.fullmatch(r'let\s+(\w+)\s*=\s*properties\["([^"]+)"\]\s+as\?\s+(\w+)', cond)
                if let_match:
                    var_name, key, kind = let_match.groups()
                    val = swift_prop(props, key, kind)
                    if val is None:
                        return message
                    env[var_name] = val
                    continue
                py_expr = re.sub(
                    r'properties\["([^"]+)"\]\s+as\?\s+(\w+)',
                    lambda m: f'_prop({m.group(1)!r}, {m.group(2)!r})',
                    cond,
                )
                py_expr = py_expr.replace('hasCustomFanCurveCapability(properties)', '_has_cap()')
                py_expr = py_expr.replace('||', ' or ').replace('&&', ' and ')
                py_expr = re.sub(r'\btrue\b', 'True', py_expr)
                py_expr = re.sub(r'\bfalse\b', 'False', py_expr)
                passed = eval(
                    py_expr,
                    {'__builtins__': {}},
                    {
                        'ioClass': env['ioClass'],
                        '_prop': lambda k, kind: swift_prop(props, k, kind),
                        '_has_cap': lambda: eval_has_custom_curve(props),
                    },
                )
                if not passed:
                    return message
            return None

        def eval_supported(props):
            return eval_unavailable_reason(props) is None

        # IdeaVPC with CustomFanCurve=True and EC Capability absent (nil) -> supported
        legion_nil_ec = {
            'IOClass': 'IdeaVPC',
            'CustomFanCurve': True,
            'ThinkFanProtocolVersion': 1,
            'ThinkFanCurveVersion': 1,
        }
        self.assertIsNone(eval_unavailable_reason(legion_nil_ec))
        self.assertTrue(eval_supported(legion_nil_ec))

        # IdeaVPC with CustomFanCurve=True and EC Capability="Basic" -> supported
        legion_basic_ec = dict(legion_nil_ec, **{'EC Capability': 'Basic'})
        self.assertIsNone(eval_unavailable_reason(legion_basic_ec))
        self.assertTrue(eval_supported(legion_basic_ec))

        # IdeaVPC with FeatureStatus["CustomFanCurve"]["Available"] = True and EC Capability="Basic" -> supported
        legion_feature_status = {
            'IOClass': 'IdeaVPC',
            'FeatureStatus': {'CustomFanCurve': {'Available': True}},
            'ThinkFanProtocolVersion': 1,
            'ThinkFanCurveVersion': 1,
            'EC Capability': 'Basic',
        }
        self.assertIsNone(eval_unavailable_reason(legion_feature_status))
        self.assertTrue(eval_supported(legion_feature_status))

        # IdeaVPC without CustomFanCurve capability -> rejected
        ideavpc_no_curve = {
            'IOClass': 'IdeaVPC',
            'ThinkFanProtocolVersion': 1,
            'ThinkFanCurveVersion': 1,
            'EC Capability': 'Basic',
        }
        self.assertEqual(
            eval_unavailable_reason(ideavpc_no_curve),
            'Custom Curve is not supported by this driver interface.',
        )
        self.assertFalse(eval_supported(ideavpc_no_curve))

        # IdeaVPC in SafeMode -> rejected with Safe Mode message
        legion_safemode = dict(legion_basic_ec, SafeMode=True)
        self.assertTrue(eval_unavailable_reason(legion_safemode).startswith('Safe Mode'))
        self.assertFalse(eval_supported(legion_safemode))

        # ThinkVPC with EC Capability="Basic" -> still requires RW helpers
        thinkvpc_basic = {
            'IOClass': 'ThinkVPC',
            'ThinkFanProtocolVersion': 1,
            'ThinkFanCurveVersion': 1,
            'EC Capability': 'Basic',
        }
        self.assertIn('Generate ThinkPad SSDT', eval_unavailable_reason(thinkvpc_basic))
        self.assertFalse(eval_supported(thinkvpc_basic))

        # ThinkVPC with EC Capability="RW" -> supported
        thinkvpc_rw = dict(thinkvpc_basic, **{'EC Capability': 'RW'})
        self.assertIsNone(eval_unavailable_reason(thinkvpc_rw))
        self.assertTrue(eval_supported(thinkvpc_rw))

    def test_add_curve_point_preserves_full_speed_0x47(self):
        cooling = (ROOT / 'ReYogaSMCApp/Views/Controls/CoolingControlsPage.swift').read_text(encoding='utf-8')
        helper = (ROOT / 'ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift').read_text(encoding='utf-8')
        add_fn = function(cooling, 'private func addCurvePoint(')
        valid_fn = function(helper, 'static func valid(')

        # Verify production source uses the 0x47-preserving level formulas on both insertion paths.
        self.assertIn(
            'let newLevel = prev.level == 0x47 ? 0x47 : min(max(prev.level, 1), min(next.level, 7))',
            add_fn,
        )
        self.assertIn(
            'let insertedLevel = prev.level == 0x47 ? 0x47 : min(max(prev.level, 1), 7)',
            add_fn,
        )
        self.assertIn('(2...10).contains(points.count)', valid_fn)

        def is_valid(points):
            if not (2 <= len(points) <= 10) or points[-1][1] != 0x47:
                return False
            for idx, (temp, lvl) in enumerate(points):
                if not (30 <= temp <= 95):
                    return False
                if not (1 <= lvl <= 7 or lvl == 0x47):
                    return False
                if idx > 0 and (points[idx - 1][0] >= temp or points[idx - 1][1] > lvl):
                    return False
            return True

        def eval_add_curve_point(draft):
            if len(draft) >= 10:
                return draft
            if not draft:
                return [(50, 4), (70, 5), (80, 7), (88, 0x47)]
            if len(draft) == 1:
                only_t, only_l = draft[0]
                if only_t > 30:
                    return [(max(30, only_t - 5), min(only_l, 7)), draft[0]]
                return [draft[0], (95, 0x47)]
            best_index = -1
            largest_gap = 1
            for i in range(len(draft) - 1):
                gap = draft[i + 1][0] - draft[i][0]
                if gap > largest_gap:
                    largest_gap = gap
                    best_index = i
            if best_index >= 0:
                prev_t, prev_l = draft[best_index]
                next_t, next_l = draft[best_index + 1]
                new_temp = min(94, max(30, (prev_t + next_t) // 2))
                new_level = 0x47 if prev_l == 0x47 else min(max(prev_l, 1), min(next_l, 7))
                return draft[:best_index + 1] + [(new_temp, new_level)] + draft[best_index + 1:]
            if draft[0][0] > 30:
                first_t, first_l = draft[0]
                return [(max(30, first_t - 5), min(first_l, 7))] + draft
            last_index = len(draft) - 1
            prev_t, prev_l = draft[last_index - 1]
            last_t, last_l = draft[last_index]
            if last_t < 95 and last_t > prev_t:
                inserted_temp = last_t
                shifted_last = (min(95, last_t + 1), last_l)
                inserted_level = 0x47 if prev_l == 0x47 else min(max(prev_l, 1), 7)
                return draft[:last_index] + [(inserted_temp, inserted_level), shifted_last]
            return draft

        # Midpoint insertion after prev.level == 0x47 preserves 0x47 and stays valid
        midpoint = eval_add_curve_point([(88, 0x47), (91, 0x47)])
        self.assertEqual(midpoint, [(88, 0x47), (89, 0x47), (91, 0x47)])
        self.assertTrue(is_valid(midpoint))

        # End-shift insertion when prev.level == 0x47 preserves 0x47 and stays valid
        end_shift = eval_add_curve_point([(30, 0x47), (31, 0x47)])
        self.assertEqual(end_shift, [(30, 0x47), (31, 0x47), (32, 0x47)])
        self.assertTrue(is_valid(end_shift))

        # Clustered 9-point curve ending with consecutive 0x47 points stays valid at 10 points
        clustered = [(30 + i, 1 + min(i, 5)) for i in range(6)] + [(36, 0x47), (37, 0x47), (38, 0x47)]
        clustered_next = eval_add_curve_point(clustered)
        self.assertEqual(len(clustered_next), 10)
        self.assertEqual(clustered_next[-2], (38, 0x47))
        self.assertEqual(clustered_next[-1], (39, 0x47))
        self.assertTrue(is_valid(clustered_next))

        # Repeated additions from 2 points up to 10 points with early 0x47 remain valid at every step
        for start in ([(30, 0x47), (31, 0x47)], [(30, 0x47), (95, 0x47)], [(50, 4), (70, 0x47), (90, 0x47)]):
            cur = list(start)
            while len(cur) < 10:
                cur = eval_add_curve_point(cur)
                self.assertTrue(is_valid(cur), f'Invalid curve after add from {start}: {cur}')

    def test_ideavpc_telemetry_resolution_preserves_legacy_rpm(self):
        hw_manager = (ROOT / 'ReYogaSMCApp/Hardware/HardwareManager.swift').read_text(encoding='utf-8')
        think_fan_helper = (ROOT / 'ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift').read_text(encoding='utf-8')
        snapshot_src = (ROOT / 'ReYogaSMCApp/Hardware/Controls/HardwareSnapshot.swift').read_text(encoding='utf-8')
        identity_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPCIdentity.cpp').read_text(encoding='utf-8')
        ideavpc_src = (ROOT / 'ReYogaSMC/Platform/IdeaVPC.cpp').read_text(encoding='utf-8')

        accept_fn = function(hw_manager, 'private func accept(')
        fan_thermal_fn = function(hw_manager, 'private func acceptFanAndThermalSnapshot(')
        refresh_fn = function(hw_manager, 'private func refreshSnapshot(')
        accept_level_fn = function(think_fan_helper, 'private func acceptLevel(')
        update_curve_fn = function(think_fan_helper, 'func updateCurve(')

        # IdeaVPC always publishes FeaturePollingVersion = 1 and removes ThinkFanTelemetryVersion
        self.assertIn('setProperty("FeaturePollingVersion", 1, 32);', ideavpc_src)
        self.assertNotIn('setProperty("ThinkFanTelemetryVersion"', identity_src)

        # HardwareManager must require props["ThinkFanTelemetry"] != nil for thinkFanTelemetrySupported
        m = re.search(r'publish\(\\\.thinkFanTelemetrySupported,\s*([^\n]+)\)', accept_fn)
        self.assertIsNotNone(m, 'thinkFanTelemetrySupported must be published with explicit condition')
        telemetry_expr = m.group(1)
        self.assertIn('props["ThinkFanTelemetry"] != nil', telemetry_expr)
        self.assertIn('props["ThinkFanTelemetryVersion"] as? Int == 1', telemetry_expr)
        self.assertIn('if thinkFanTelemetrySupported', fan_thermal_fn)
        self.assertIn('publish(\\.fan1RPM, HardwareSnapshot.fanRPM(props["Fan1RPM"]))', fan_thermal_fn)
        self.assertIn('publish(\\.fan2RPM, HardwareSnapshot.fanRPM(props["Fan2RPM"]))', fan_thermal_fn)
        self.assertIn('(0..<0xffff).contains(value)', snapshot_src)

        # Extract the real Swift refresh expressions and guard from HardwareManager.refreshSnapshot
        fw_match = re.search(r'let refreshFirmware = ([\s\S]*?)\n\s*if refreshFirmware', refresh_fn)
        tf_match = re.search(r'let refreshThinkFans = ([^\n]+)', refresh_fn)
        ca_match = re.search(r'let curveActive = ([^\n]+)', refresh_fn)
        legacy_match = re.search(r'let refreshLegacyThinkFans = ([\s\S]*?)\n\s*if refreshLegacyThinkFans', refresh_fn)
        guard_match = re.search(r'if refreshLegacyThinkFans,\s*([^\n{]+)\{', refresh_fn)
        self.assertIsNotNone(fw_match)
        self.assertIsNotNone(tf_match)
        self.assertIsNotNone(ca_match)
        self.assertIsNotNone(legacy_match)
        self.assertIsNotNone(guard_match)

        fw_swift = ' '.join(fw_match.group(1).split())
        tf_swift = ' '.join(tf_match.group(1).split())
        ca_swift = ' '.join(ca_match.group(1).split())
        legacy_swift = ' '.join(legacy_match.group(1).split())
        guard_swift = ' '.join(guard_match.group(1).split())

        # Legacy polling must NOT depend on refreshFirmware and MUST run before updateCurve
        self.assertNotIn('refreshFirmware', legacy_swift)
        self.assertIn('curveActive', legacy_swift)
        self.assertIn('lastLegacyFanRefresh', legacy_swift)
        self.assertLess(refresh_fn.index('self.fanHelper?.update()'), refresh_fn.index('fan.updateCurve('))

        # ThinkFanHelper acceptLevel(0x84) must stop curve and updateCurve must guard on curveEnabled
        self.assertIn('if curveEnabled && !curveRequestPending {', accept_level_fn)
        self.assertIn('curveEnabled = false', accept_level_fn)
        self.assertIn('curveStatus = "BIOS Auto"', accept_level_fn)
        self.assertIn('curveStopReason = "Curve stopped: driver fell back to BIOS Auto."', accept_level_fn)
        self.assertIn('guard curveEnabled else { return }', update_curve_fn)

        def swift_int(val):
            return val if (type(val) is int) else None

        def swift_expr_to_py(expr):
            py = expr
            py = re.sub(
                r'\["ThinkVPC", "IdeaVPC"\]\.contains\(providerClass\)',
                'providerClass in ("ThinkVPC", "IdeaVPC")',
                py,
            )
            py = re.sub(
                r'Date\(\)\.timeIntervalSince\((last\w+)\)',
                r'(now - \1)',
                py,
            )
            py = re.sub(
                r'(\w+)\?\.curveEnabled == true',
                r'(\1 is not None and \1.curveEnabled is True)',
                py,
            )
            py = re.sub(
                r'(\w+)\["([^"]+)"\]\s*==\s*nil',
                r'(\1.get("\2") is None)',
                py,
            )
            py = re.sub(
                r'(\w+)\["([^"]+)"\]\s*!=\s*nil',
                r'(\1.get("\2") is not None)',
                py,
            )
            py = re.sub(
                r'(\w+)\["([^"]+)"\]\s+as\?\s+Int\s*==\s*(\d+)',
                r'(_swift_int(\1.get("\2")) == \3)',
                py,
            )
            py = re.sub(
                r'(\w+)\["([^"]+)"\]\s+as\?\s+Int\s*!=\s*(\d+)',
                r'(_swift_int(\1.get("\2")) != \3)',
                py,
            )
            py = py.replace('&&', ' and ').replace('||', ' or ')
            py = re.sub(r'!(?!=)', 'not ', py)
            py = re.sub(r'\btrue\b', 'True', py)
            py = re.sub(r'\bfalse\b', 'False', py)
            return py

        telemetry_py = swift_expr_to_py(telemetry_expr)
        fw_py = swift_expr_to_py(fw_swift)
        tf_py = swift_expr_to_py(tf_swift)
        ca_py = swift_expr_to_py(ca_swift)
        legacy_py = swift_expr_to_py(legacy_swift)
        guard_py = swift_expr_to_py(guard_swift)

        def eval_fan_rpm(val):
            if type(val) is int and 0 <= val < 0xffff:
                return val
            return -1

        class SimFanHelper:
            def __init__(self, driver, fan_idx):
                self.driver = driver
                self.fan_idx = fan_idx
                self.enable = True
                self.curveEnabled = False
                self.curveRequestPending = False
                self.curveStatus = ''
                self.curveStopReason = ''
                self.savedLevel = 0x84
                self.rpm = None
                self.update_calls = 0

            def accept_level(self, raw):
                if raw & 0x40:
                    self.savedLevel = 0x47
                elif raw & 0x80:
                    self.savedLevel = 0x84
                    if self.curveEnabled and not self.curveRequestPending:
                        self.curveEnabled = False
                        self.curveStatus = 'BIOS Auto'
                        self.curveStopReason = 'Curve stopped: driver fell back to BIOS Auto.'
                elif raw <= 7:
                    self.savedLevel = raw

            def update(self):
                self.update_calls += 1
                rpm, ctrl = self.driver.query_rpm(self.fan_idx)
                self.rpm = rpm
                self.accept_level(ctrl)

            def update_curve(self, temp):
                if not self.curveEnabled:
                    return
                # Mirror ThinkFanHelper.updateCurve: writes selector 6
                self.driver.write_curve_level(self.fan_idx, 4)

        class SimDriver:
            def __init__(self, props):
                self.props = dict(props)
                self.active_control = [0x84, 0x84]
                self.lease_active = False
                self.update_cmd_calls = 0
                self.update_fans_cmd_calls = 0
                self.curve_writes = []

            def query_rpm(self, fan_idx):
                key = 'Fan1RPM' if fan_idx == 0 else 'Fan2RPM'
                return eval_fan_rpm(self.props.get(key)), self.active_control[fan_idx]

            def write_curve_level(self, fan_idx, level):
                self.active_control[fan_idx] = level
                self.lease_active = True
                self.curve_writes.append((fan_idx, level))

            def fallback_to_auto(self):
                self.active_control = [0x84, 0x84]
                self.lease_active = False

        class SimManager:
            def __init__(self, driver):
                self.driver = driver
                self.providerClass = ''
                self.featurePollingSupported = False
                self.thinkFanTelemetrySupported = False
                self.lastFirmwareRefresh = -1e9
                self.lastLegacyFanRefresh = -1e9
                self.fanHelper = SimFanHelper(driver, 0)
                self.fanHelper2 = SimFanHelper(driver, 1)
                self.fan1RPM = -1
                self.fan2RPM = -1

            def eval_expr(self, py_expr, extra=None):
                env = {
                    'providerClass': self.providerClass,
                    'featurePollingSupported': self.featurePollingSupported,
                    'thinkFanTelemetrySupported': self.thinkFanTelemetrySupported,
                    'lastFirmwareRefresh': self.lastFirmwareRefresh,
                    'lastLegacyFanRefresh': self.lastLegacyFanRefresh,
                    'fanHelper': self.fanHelper,
                    'fanHelper2': self.fanHelper2,
                    '_swift_int': swift_int,
                }
                if extra:
                    env.update(extra)
                return bool(eval(py_expr, {'__builtins__': {}}, env))

            def refresh_snapshot(self, now, full=False):
                refresh_fw = self.eval_expr(fw_py, {'full': full, 'now': now})
                if refresh_fw:
                    self.lastFirmwareRefresh = now
                refresh_tf = self.eval_expr(tf_py)
                curve_active = self.eval_expr(ca_py)
                refresh_legacy = self.eval_expr(
                    legacy_py, {'full': full, 'now': now, 'curveActive': curve_active}
                )
                if refresh_legacy:
                    self.lastLegacyFanRefresh = now
                if refresh_fw:
                    self.driver.update_cmd_calls += 1
                elif refresh_tf:
                    self.driver.update_fans_cmd_calls += 1

                snapshot = dict(self.driver.props)
                guard_ok = self.eval_expr(guard_py, {'snapshot': snapshot})
                if refresh_legacy and guard_ok:
                    self.fanHelper.update()
                    self.fanHelper2.update()

                # accept(snapshot)
                self.providerClass = snapshot.get('IOClass') if isinstance(snapshot.get('IOClass'), str) else ''
                self.featurePollingSupported = swift_int(snapshot.get('FeaturePollingVersion')) == 1
                self.thinkFanTelemetrySupported = self.eval_expr(telemetry_py, {'props': snapshot, 'providerClass': self.providerClass})
                if not self.thinkFanTelemetrySupported:
                    self.fan1RPM = eval_fan_rpm(snapshot.get('Fan1RPM'))
                    self.fan2RPM = eval_fan_rpm(snapshot.get('Fan2RPM'))
                else:
                    self.fan1RPM = -1
                    self.fan2RPM = -1

                # updateCurve runs after legacy poll and accept(snapshot)
                self.fanHelper.update_curve(55.0)
                self.fanHelper2.update_curve(55.0)
                return {
                    'refreshFirmware': refresh_fw,
                    'refreshThinkFans': refresh_tf,
                    'refreshLegacyThinkFans': refresh_legacy,
                    'guardOk': guard_ok,
                }

        # Realistic IdeaVPC snapshot (FeaturePollingVersion=1, ThinkFanTelemetry absent)
        ideavpc_props = {
            'IOClass': 'IdeaVPC',
            'FeaturePollingVersion': 1,
            'ThinkFanProtocolVersion': 1,
            'ThinkFanAuthorizationVersion': 1,
            'ThinkFanCurveVersion': 1,
            'Dual fan': True,
            'Fan number': 2,
            'CustomFanCurve': True,
            'Fan1RPM': 2200,
            'Fan2RPM': 2400,
        }
        driver = SimDriver(ideavpc_props)
        mgr = SimManager(driver)

        # t=0.0: initial refreshAll(full=True) while providerClass == ''
        init_flags = mgr.refresh_snapshot(now=0.0, full=True)
        self.assertTrue(init_flags['refreshFirmware'])
        self.assertFalse(init_flags['refreshLegacyThinkFans'])
        self.assertEqual(mgr.providerClass, 'IdeaVPC')
        self.assertTrue(mgr.featurePollingSupported)
        self.assertFalse(mgr.thinkFanTelemetrySupported)
        self.assertEqual(mgr.fan1RPM, 2200)
        self.assertEqual(mgr.fan2RPM, 2400)

        # Periodic monitoring ticks (full=False) when curve is inactive:
        # refreshFirmware MUST remain False (no Update=true sent), while legacy fan polling runs every >=2s
        t05 = mgr.refresh_snapshot(now=0.5, full=False)
        self.assertFalse(t05['refreshFirmware'])
        self.assertTrue(t05['refreshLegacyThinkFans'])
        self.assertEqual(driver.update_cmd_calls, 1)  # only the initial full=True call
        self.assertEqual(mgr.fanHelper.update_calls, 1)

        t15 = mgr.refresh_snapshot(now=1.5, full=False)
        self.assertFalse(t15['refreshFirmware'])
        self.assertFalse(t15['refreshLegacyThinkFans'])  # throttled <2s while curve inactive
        self.assertEqual(mgr.fanHelper.update_calls, 1)

        t25 = mgr.refresh_snapshot(now=2.5, full=False)
        self.assertFalse(t25['refreshFirmware'])
        self.assertTrue(t25['refreshLegacyThinkFans'])  # >=2s elapsed
        self.assertEqual(mgr.fanHelper.update_calls, 2)
        self.assertEqual(driver.update_cmd_calls, 1)

        # Activate curve on fanHelper (curveEnabled=True) and simulate driver fallback to 0x84
        mgr.fanHelper.curveEnabled = True
        mgr.fanHelper.savedLevel = 4
        driver.write_curve_level(0, 4)
        driver.write_curve_level(1, 4)
        writes_before_fallback = len(driver.curve_writes)

        # Driver falls back to BIOS Auto (0x84) e.g. via Fn+Q SmartFanMode change
        driver.fallback_to_auto()
        self.assertEqual(driver.active_control, [0x84, 0x84])
        self.assertFalse(driver.lease_active)

        # Very next active monitoring tick (t=3.0s, <2s since t=2.5s!):
        # refreshLegacyThinkFans MUST be True because curveActive is True,
        # fanHelper.update() MUST detect 0x84 via acceptLevel(0x84) BEFORE updateCurve,
        # and updateCurve MUST NOT overwrite 0x84 or re-arm the driver lease.
        t30 = mgr.refresh_snapshot(now=3.0, full=False)
        self.assertFalse(t30['refreshFirmware'])
        self.assertTrue(t30['refreshLegacyThinkFans'])
        self.assertEqual(mgr.fanHelper.update_calls, 3)
        self.assertFalse(mgr.fanHelper.curveEnabled)
        self.assertEqual(mgr.fanHelper.curveStatus, 'BIOS Auto')
        self.assertEqual(mgr.fanHelper.curveStopReason, 'Curve stopped: driver fell back to BIOS Auto.')
        self.assertEqual(mgr.fanHelper.savedLevel, 0x84)
        self.assertEqual(driver.active_control, [0x84, 0x84])
        self.assertFalse(driver.lease_active)
        self.assertEqual(len(driver.curve_writes), writes_before_fallback)

        # Subsequent tick must also keep fan in BIOS Auto and never re-arm
        t35 = mgr.refresh_snapshot(now=3.5, full=False)
        self.assertFalse(t35['refreshFirmware'])
        self.assertEqual(driver.active_control, [0x84, 0x84])
        self.assertFalse(driver.lease_active)
        self.assertEqual(len(driver.curve_writes), writes_before_fallback)

        # Defensive guard: even if ThinkFanTelemetryVersion == 1 without ThinkFanTelemetry,
        # RPMs are preserved AND legacy fan polling still runs
        driver_ver_only = SimDriver(dict(ideavpc_props, ThinkFanTelemetryVersion=1))
        mgr_ver_only = SimManager(driver_ver_only)
        mgr_ver_only.refresh_snapshot(now=0.0, full=True)
        res_ver_only = mgr_ver_only.refresh_snapshot(now=0.5, full=False)
        self.assertFalse(mgr_ver_only.thinkFanTelemetrySupported)
        self.assertEqual(mgr_ver_only.fan1RPM, 2200)
        self.assertEqual(mgr_ver_only.fan2RPM, 2400)
        self.assertFalse(res_ver_only['refreshFirmware'])
        self.assertTrue(res_ver_only['refreshLegacyThinkFans'])
        self.assertTrue(res_ver_only['guardOk'])
        self.assertEqual(mgr_ver_only.fanHelper.update_calls, 1)

        # ThinkVPC with full ThinkFanTelemetry dictionary uses combined telemetry path
        thinkvpc_full = {
            'IOClass': 'ThinkVPC',
            'ThinkFanTelemetryVersion': 1,
            'ThinkFanTelemetry': {'Fan1': {'RPM': 3100, 'Control': 4}, 'SensorSampleTimeMS': 1000},
        }
        driver_think = SimDriver(thinkvpc_full)
        mgr_think = SimManager(driver_think)
        mgr_think.refresh_snapshot(now=0.0, full=True)
        res_think = mgr_think.refresh_snapshot(now=0.5, full=False)
        self.assertTrue(mgr_think.thinkFanTelemetrySupported)
        self.assertTrue(res_think['refreshThinkFans'])
        self.assertFalse(res_think['refreshLegacyThinkFans'])
        self.assertFalse(res_think['guardOk'])
        self.assertEqual(mgr_think.fanHelper.update_calls, 0)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_swift_compiled_ideavpc_curve_policy_and_add_point(self):
        helper = (ROOT / 'ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift').read_text(encoding='utf-8')
        cooling = (ROOT / 'ReYogaSMCApp/Views/Controls/CoolingControlsPage.swift').read_text(encoding='utf-8')
        hw_manager = (ROOT / 'ReYogaSMCApp/Hardware/HardwareManager.swift').read_text(encoding='utf-8')
        snapshot_src = (ROOT / 'ReYogaSMCApp/Hardware/Controls/HardwareSnapshot.swift').read_text(encoding='utf-8')
        policy_fn = function(helper, 'static func hasCustomFanCurveCapability(')
        reason_fn = function(helper, 'static func unavailableReason(')
        valid_fn = function(helper, 'static func valid(')
        add_fn = function(cooling, 'private func addCurvePoint(').replace('private func ', 'mutating func ')
        fan_rpm_fn = function(snapshot_src, 'static func fanRPM(')
        integer_fn = function(snapshot_src, 'static func integer(')
        accept_fn = function(hw_manager, 'private func accept(')
        refresh_fn = function(hw_manager, 'private func refreshSnapshot(')
        m = re.search(r'publish\(\\\.thinkFanTelemetrySupported,\s*([^\n]+)\)', accept_fn)
        self.assertIsNotNone(m)
        telemetry_expr = m.group(1)
        fw_match = re.search(r'let refreshFirmware = ([\s\S]*?)\n\s*if refreshFirmware', refresh_fn)
        legacy_match = re.search(r'let refreshLegacyThinkFans = ([\s\S]*?)\n\s*if refreshLegacyThinkFans', refresh_fn)
        guard_match = re.search(r'if refreshLegacyThinkFans,\s*([^\n{]+)\{', refresh_fn)
        self.assertIsNotNone(fw_match)
        self.assertIsNotNone(legacy_match)
        self.assertIsNotNone(guard_match)
        fw_expr = fw_match.group(1)
        legacy_expr = legacy_match.group(1)
        guard_expr = guard_match.group(1)
        swift_source = f'''import Foundation
import CoreFoundation

struct ThinkFanCurvePoint: Equatable {{
    var temperature: Int
    var level: Int
}}

struct ThinkFanCurvePolicy {{
    static func supported(_ properties: NSDictionary) -> Bool {{
        unavailableReason(properties) == nil
    }}
    {policy_fn}
    {reason_fn}
    static let defaults = [ThinkFanCurvePoint(temperature: 50, level: 4),
        ThinkFanCurvePoint(temperature: 70, level: 5), ThinkFanCurvePoint(temperature: 80, level: 7),
        ThinkFanCurvePoint(temperature: 88, level: 0x47)]
    {valid_fn}
}}

struct DraftEditor {{
    var curveDraft: [ThinkFanCurvePoint]
    {add_fn}
}}

struct SnapshotHelper {{
    {integer_fn}
    {fan_rpm_fn}
}}

let ideaNilEC: NSDictionary = [
    "IOClass": "IdeaVPC",
    "CustomFanCurve": true,
    "ThinkFanProtocolVersion": 1,
    "ThinkFanCurveVersion": 1
]
precondition(ThinkFanCurvePolicy.unavailableReason(ideaNilEC) == nil)
precondition(ThinkFanCurvePolicy.supported(ideaNilEC))

let ideaBasicEC: NSDictionary = [
    "IOClass": "IdeaVPC",
    "CustomFanCurve": true,
    "ThinkFanProtocolVersion": 1,
    "ThinkFanCurveVersion": 1,
    "EC Capability": "Basic"
]
precondition(ThinkFanCurvePolicy.unavailableReason(ideaBasicEC) == nil)
precondition(ThinkFanCurvePolicy.supported(ideaBasicEC))

let ideaNoCurve: NSDictionary = [
    "IOClass": "IdeaVPC",
    "ThinkFanProtocolVersion": 1,
    "ThinkFanCurveVersion": 1,
    "EC Capability": "Basic"
]
precondition(ThinkFanCurvePolicy.unavailableReason(ideaNoCurve) != nil)
precondition(!ThinkFanCurvePolicy.supported(ideaNoCurve))

var tightUpper = DraftEditor(curveDraft: [
    ThinkFanCurvePoint(temperature: 50, level: 4),
    ThinkFanCurvePoint(temperature: 94, level: 7),
    ThinkFanCurvePoint(temperature: 95, level: 0x47)
])
tightUpper.addCurvePoint()
precondition(tightUpper.curveDraft.count == 4 && ThinkFanCurvePolicy.valid(tightUpper.curveDraft))

var adjacentPair = DraftEditor(curveDraft: [
    ThinkFanCurvePoint(temperature: 94, level: 7),
    ThinkFanCurvePoint(temperature: 95, level: 0x47)
])
adjacentPair.addCurvePoint()
precondition(adjacentPair.curveDraft.count == 3 && ThinkFanCurvePolicy.valid(adjacentPair.curveDraft))

var lowPair = DraftEditor(curveDraft: [
    ThinkFanCurvePoint(temperature: 30, level: 1),
    ThinkFanCurvePoint(temperature: 31, level: 0x47)
])
lowPair.addCurvePoint()
precondition(lowPair.curveDraft.count == 3 && ThinkFanCurvePolicy.valid(lowPair.curveDraft))

var midpointFull = DraftEditor(curveDraft: [
    ThinkFanCurvePoint(temperature: 88, level: 0x47),
    ThinkFanCurvePoint(temperature: 91, level: 0x47)
])
midpointFull.addCurvePoint()
precondition(midpointFull.curveDraft.count == 3)
precondition(midpointFull.curveDraft[1].level == 0x47)
precondition(ThinkFanCurvePolicy.valid(midpointFull.curveDraft))

var adjacentFull = DraftEditor(curveDraft: [
    ThinkFanCurvePoint(temperature: 30, level: 0x47),
    ThinkFanCurvePoint(temperature: 31, level: 0x47)
])
while adjacentFull.curveDraft.count < 10 {{
    adjacentFull.addCurvePoint()
    precondition(ThinkFanCurvePolicy.valid(adjacentFull.curveDraft))
}}
precondition(adjacentFull.curveDraft.allSatisfy {{ $0.level == 0x47 }})

var mixedFull = DraftEditor(curveDraft: [
    ThinkFanCurvePoint(temperature: 50, level: 4),
    ThinkFanCurvePoint(temperature: 70, level: 0x47),
    ThinkFanCurvePoint(temperature: 90, level: 0x47)
])
while mixedFull.curveDraft.count < 10 {{
    mixedFull.addCurvePoint()
    precondition(ThinkFanCurvePolicy.valid(mixedFull.curveDraft))
}}

func evaluateTelemetry(props: NSDictionary) -> (supported: Bool, fan1: Int, fan2: Int) {{
    let providerClass = (props["IOClass"] as? String) ?? ""
    let supported = {telemetry_expr}
    if supported {{
        return (true, -1, -1)
    }}
    return (false, SnapshotHelper.fanRPM(props["Fan1RPM"]), SnapshotHelper.fanRPM(props["Fan2RPM"]))
}}

let ideaTelemetryAbsent: NSDictionary = [
    "IOClass": "IdeaVPC",
    "ThinkFanProtocolVersion": 1,
    "ThinkFanCurveVersion": 1,
    "CustomFanCurve": true,
    "Fan1RPM": 2200,
    "Fan2RPM": 2400
]
let ideaResult = evaluateTelemetry(props: ideaTelemetryAbsent)
precondition(!ideaResult.supported && ideaResult.fan1 == 2200 && ideaResult.fan2 == 2400)

let ideaVersionOnly: NSDictionary = [
    "IOClass": "IdeaVPC",
    "ThinkFanProtocolVersion": 1,
    "ThinkFanCurveVersion": 1,
    "ThinkFanTelemetryVersion": 1,
    "CustomFanCurve": true,
    "Fan1RPM": 2200,
    "Fan2RPM": 2400
]
let ideaVersionOnlyResult = evaluateTelemetry(props: ideaVersionOnly)
precondition(!ideaVersionOnlyResult.supported && ideaVersionOnlyResult.fan1 == 2200 && ideaVersionOnlyResult.fan2 == 2400)

struct FakeFanHelper {{
    var curveEnabled = false
}}

func evaluateLegacyRefresh(providerClass: String, featurePollingSupported: Bool,
                           thinkFanTelemetrySupported: Bool, full: Bool,
                           curveActive: Bool, lastFirmwareRefresh: Date,
                           lastLegacyFanRefresh: Date, snapshot: NSDictionary) -> (fw: Bool, legacy: Bool, guardOK: Bool) {{
    let refreshFirmware = {fw_expr}
    let refreshLegacyThinkFans = {legacy_expr}
    let guardOK = {guard_expr}
    return (refreshFirmware, refreshLegacyThinkFans, guardOK)
}}

let recent = Date()
let stale = Date().addingTimeInterval(-5)
let ideaPeriodicInactive = evaluateLegacyRefresh(
    providerClass: "IdeaVPC", featurePollingSupported: true, thinkFanTelemetrySupported: false,
    full: false, curveActive: false, lastFirmwareRefresh: recent, lastLegacyFanRefresh: stale, snapshot: ideaTelemetryAbsent
)
precondition(!ideaPeriodicInactive.fw && ideaPeriodicInactive.legacy && ideaPeriodicInactive.guardOK)

let ideaPeriodicActiveCurve = evaluateLegacyRefresh(
    providerClass: "IdeaVPC", featurePollingSupported: true, thinkFanTelemetrySupported: false,
    full: false, curveActive: true, lastFirmwareRefresh: recent, lastLegacyFanRefresh: recent, snapshot: ideaTelemetryAbsent
)
precondition(!ideaPeriodicActiveCurve.fw && ideaPeriodicActiveCurve.legacy && ideaPeriodicActiveCurve.guardOK)

let ideaVersionOnlyRefresh = evaluateLegacyRefresh(
    providerClass: "IdeaVPC", featurePollingSupported: true, thinkFanTelemetrySupported: false,
    full: false, curveActive: true, lastFirmwareRefresh: recent, lastLegacyFanRefresh: recent, snapshot: ideaVersionOnly
)
precondition(!ideaVersionOnlyRefresh.fw && ideaVersionOnlyRefresh.legacy && ideaVersionOnlyRefresh.guardOK)
'''
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / 'policy_test.swift'
            source.write_text(swift_source, encoding='utf-8')
            executable = pathlib.Path(directory) / 'policy_test'
            build = subprocess.run(['swiftc', '-swift-version', '5', str(source), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run_result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run_result.returncode, 0, run_result.stdout + run_result.stderr)



@unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
class LegionFanCurveCompiledTests(unittest.TestCase):
    def test_production_fan_curve_and_watchdog_replay(self):
        production = kernel_sources('IdeaVPC')
        base_production = kernel_sources('ReYogaVPC')
        uc_production = kernel_sources('ReYogaSMCUserClient')

        # Extract real IdeaVPC production implementations
        has_verified_fn = function(production, 'bool IdeaVPC::hasVerifiedLegionCurveProfile(')
        supported_fn = function(production, 'bool IdeaVPC::isLegionFanCurveSupported(')
        val_fn = function(production, 'bool IdeaVPC::validateFanCurveTable(')
        capture_fn = function(production, 'bool IdeaVPC::captureFactoryCurveTable(')
        apply_fn = function(production, 'IOReturn IdeaVPC::applyLegionFanCurveTable(')
        readback_fn = function(production, 'IOReturn IdeaVPC::readbackLegionFanCurveTable(')
        engage_fs_fn = function(production, 'IOReturn IdeaVPC::engageFullSpeed(')
        disengage_fs_fn = function(production, 'IOReturn IdeaVPC::disengageFullSpeed(')
        read_ctrl_fn = function(production, 'IOReturn IdeaVPC::readHardwareFanControl(')
        curve_fn = function(production, 'IOReturn IdeaVPC::accessPlatformFanCurve(')
        expire_fn = function(production, 'void IdeaVPC::expireLegionFanCurve(')
        fan_fn = function(production, 'IOReturn IdeaVPC::accessPlatformFan(')
        gated_fn = function(production, 'IOReturn IdeaVPC::accessLegionFanGated(')
        restore_pub_fn = function(production, 'void IdeaVPC::restorePlatformFans(')
        restore_fn = function(production, 'IOReturn IdeaVPC::restorePlatformFansGated(')
        rpm_fn = function(production, 'IOReturn IdeaVPC::readPlatformFanRPM(')
        power_fn = function(production, 'IOReturn IdeaVPC::setPowerStateGated(')
        restore_uc_fn = function(production, 'void IdeaVPC::restoreUserControls(')
        set_ctrl_fn = function(production, 'IOReturn IdeaVPC::setControl(')

        # Extract real ReYogaVPC forwarding methods
        vpc_fns = '\n'.join(function(base_production, sig) for sig in (
            'IOReturn ReYogaVPC::accessThinkFan(',
            'IOReturn ReYogaVPC::accessThinkFanCurve(',
            'IOReturn ReYogaVPC::readThinkFanRPM(',
            'void ReYogaVPC::restoreThinkFans(',
        ))

        # Extract real ReYogaSMCUserClient dispatch, lifecycle, and authorization methods
        uc_fns = '\n'.join(function(uc_production, sig) for sig in (
            'IOReturn ReYogaSMCUserClient::externalMethod(',
            'IOReturn ReYogaSMCUserClient::dispatchGated(',
            'IOReturn ReYogaSMCUserClient::methodOpen(',
            'IOReturn ReYogaSMCUserClient::methodClose(',
            'IOReturn ReYogaSMCUserClient::methodThinkFan(',
            'IOReturn ReYogaSMCUserClient::methodThinkFanCurve(',
            'IOReturn ReYogaSMCUserClient::methodAuthorizeThinkFan(',
            'IOReturn ReYogaSMCUserClient::openGated(',
            'IOReturn ReYogaSMCUserClient::closeGated(',
            'IOReturn ReYogaSMCUserClient::closeGatedAction(',
            'IOReturn ReYogaSMCUserClient::thinkFanGated(',
            'IOReturn ReYogaSMCUserClient::clientClose(',
            'IOReturn ReYogaSMCUserClient::clientDied(',
        ))

        prod_code = '\n'.join([
            has_verified_fn, supported_fn, val_fn, capture_fn, apply_fn, readback_fn,
            engage_fs_fn, disengage_fs_fn, read_ctrl_fn, curve_fn, expire_fn, fan_fn,
            gated_fn, restore_pub_fn, restore_fn, rpm_fn, power_fn, restore_uc_fn,
            set_ctrl_fn, vpc_fns, uc_fns,
        ])

        fixture = r'''
#include "ReYogaSMC/ControlValidation.hpp"
#include "ReYogaSMC/FirmwareIdentity.hpp"
#include "ReYogaSMC/ReYogaSMCUserClient.h"
#include "ReYogaSMC/SensorDescriptors.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>

using UInt32 = uint32_t;
using UInt64 = uint64_t;
using UInt16 = uint16_t;
using UInt8 = uint8_t;
using IOReturn = int;
using IOByteCount = unsigned long;
using IOPhysicalAddress = uint64_t;

constexpr int kIOReturnSuccess = 0;
constexpr int kIOReturnBadArgument = 1;
constexpr int kIOReturnUnsupported = 2;
constexpr int kIOReturnNotReady = 3;
constexpr int kIOReturnNotAttached = 4;
constexpr int kIOReturnIOError = 5;
constexpr int kIOReturnUnderrun = 6;
constexpr int kIOReturnNotPermitted = 7;
constexpr int kIOReturnNoMemory = 8;
constexpr int kIOReturnNotOpen = 9;
constexpr int kIOReturnExclusiveAccess = 10;
constexpr int kIOPMAckImplied = 0;
constexpr int kIOReturnInvalid = 11;
constexpr int kIOReturnBusy = 12;

#define AlwaysLog(...) do {} while (0)
#define DebugLog(...) do {} while (0)
#define PE_parse_boot_argn(name, ptr, sz) ((void)(ptr), (void)(sz), 0)

static constexpr IOByteCount kLegionMinECMMIOSize = 0x300;
static constexpr IOByteCount kLegionMaxECMMIOSize = 0x10000;

static constexpr UInt32 kLegionRegPowerMode = 0x020;
static constexpr UInt32 kLegionRegLockFan = 0x0AB;
static constexpr UInt32 kLegionRegCurvePoint = 0x134;
static constexpr UInt32 kLegionRegCurveSize = 0x135;
static constexpr UInt32 kLegionRegMiniCurveCool = 0x136;
static constexpr UInt32 kLegionRegCPUTempInput = 0x138;
static constexpr UInt32 kLegionRegGPUTempInput = 0x139;
static constexpr UInt32 kLegionRegVRMTempInput = 0x13A;
static constexpr UInt32 kLegionRegFan1Base = 0x140;
static constexpr UInt32 kLegionRegFan2Base = 0x150;
static constexpr UInt32 kLegionRegFanAccBase = 0x160;
static constexpr UInt32 kLegionRegFanDecBase = 0x170;
static constexpr UInt32 kLegionRegCPUTemp = 0x180;
static constexpr UInt32 kLegionRegCPUTempHyst = 0x190;
static constexpr UInt32 kLegionRegGPUTemp = 0x1A0;
static constexpr UInt32 kLegionRegGPUTempHyst = 0x1B0;
static constexpr UInt32 kLegionRegVRMTemp = 0x1C0;
static constexpr UInt32 kLegionRegVRMTempHyst = 0x1D0;
static constexpr UInt32 kLegionRegFan1RPM = 0x1E0;
static constexpr UInt32 kLegionRegFan2RPM = 0x1E2;
static constexpr UInt32 kLegionRegCounter1 = 0x1FE;
static constexpr UInt32 kLegionRegCounter2 = 0x1FF;
static constexpr UInt32 kLegionRegCPULevel = 0x234;
static constexpr UInt32 kLegionRegGPULevel = 0x235;
static constexpr UInt32 kLegionRegHSTLevel = 0x236;

enum {
    GAME_ZONE_WMI_GET_SMARTFAN_MODE = 0x2D,
    GAME_ZONE_WMI_SET_SMARTFAN_MODE = 0x2C,
    GAME_ZONE_WMI_CAP_FAN_COOLING = 0x0C,
    GAME_ZONE_WMI_SET_OVER_DRIVE = 0x33,
    GAME_ZONE_WMI_SET_WIN_KEY = 0x16,
    GAME_ZONE_WMI_SET_TOUCHPAD = 0x19,
};

static const char *smartFanPrompt = "SmartFanMode";
static const char *fullFanPrompt = "FanFullSpeed";
static const char *alwaysOnUSBStatePrompt = "AlwaysOnUSBState";
static const char *backlightPrompt = "BacklightLevel";
static const char *conservationPrompt = "ConservationMode";
static const char *rapidChargePrompt = "RapidChargeMode";
static const char *overDrivePrompt = "DisplayOverDrive";
static const char *winKeyPrompt = "WinKeyLock";
static const char *touchpadLockPrompt = "TouchpadLock";
static const char *yLogoPrompt = "YLogoStatus";
static const char *portLightingPrompt = "PortLighting";
static const char *FnKeyPrompt = "FnlockMode";

struct OSObject {
    virtual void release() {}
    virtual ~OSObject() = default;
};

struct OSBoolean : OSObject {
    bool val{false};
    explicit OSBoolean(bool v) : val(v) {}
    bool getValue() const { return val; }
};
static OSBoolean gBoolTrue(true);
static OSBoolean gBoolFalse(false);
OSObject *const kOSBooleanTrue = &gBoolTrue;

struct OSNumber : OSObject {
    UInt64 value{0};
    bool heapAllocated{true};
    static OSNumber *withNumber(UInt64 val, unsigned) {
        auto num = new OSNumber();
        num->value = val;
        num->heapAllocated = true;
        return num;
    }
    UInt32 unsigned32BitValue() const { return static_cast<UInt32>(value); }
    UInt64 unsigned64BitValue() const { return value; }
    void release() override { if (heapAllocated) delete this; }
};

struct OSDictionary : OSObject {
    OSDictionary *child{nullptr};
    bool isLeaf{false};
    OSObject *getObject(const char *key) const {
        if (isLeaf)
            return !strcmp(key, "Available") ? kOSBooleanTrue : nullptr;
        return child;
    }
};

template <typename T>
T *OSDynamicCastImpl(OSObject *obj);
template <>
OSNumber *OSDynamicCastImpl<OSNumber>(OSObject *obj) { return dynamic_cast<OSNumber *>(obj); }
template <>
OSBoolean *OSDynamicCastImpl<OSBoolean>(OSObject *obj) { return dynamic_cast<OSBoolean *>(obj); }
template <>
OSDictionary *OSDynamicCastImpl<OSDictionary>(OSObject *obj) { return dynamic_cast<OSDictionary *>(obj); }
#define OSDynamicCast(Type, obj) OSDynamicCastImpl<Type>(static_cast<OSObject *>(obj))
#define OSSafeReleaseNULL(ptr) do { if (ptr) { (ptr)->release(); (ptr) = nullptr; } } while (0)

struct IOService : OSObject {
    virtual IOReturn evaluateInteger(const char *, UInt32 *, void * = nullptr, unsigned = 0) { return kIOReturnUnsupported; }
    virtual IOReturn setPowerState(unsigned long, IOService *) { return kIOPMAckImplied; }
};

struct IOTimerEventSource {
    unsigned arms = 0;
    bool enabled = false;
    void setTimeoutMS(unsigned) { ++arms; enabled = true; }
    void cancelTimeout() { enabled = false; }
    void enable() { enabled = true; }
    void disable() { enabled = false; }
};

struct Gate {
    OSObject *owner;
    using Action = IOReturn (*)(OSObject *, void *, void *, void *, void *);
    IOReturn runAction(Action action, void *context = nullptr) {
        return action(owner, context, nullptr, nullptr, nullptr);
    }
};

static unsigned long long nowMS = 0;
static unsigned long long legionFanTimeMS() { return nowMS; }

struct MockEC : IOService {
    bool hasRYFS = false;
    bool hasRYFF = false;
    bool hasRYFA = false;
    bool hasRYVW = true;
    bool hasRYFM = false;
    bool hasRYG = false;
    bool hasRYM = false;
    bool hasRYR = false;
    UInt32 verifiedWrites = 1;
    IOReturn transportError = kIOReturnSuccess;
    unsigned ryfsCalls = 0;
    unsigned ryffOnCalls = 0;
    unsigned ryffOffCalls = 0;
    unsigned ryfaCalls = 0;
    UInt32 ryfmMask = 0;
    UInt32 lastRyfsFan = 0;
    UInt32 lastRyfsRPM = 0;
    UInt32 rygRPM[2]{0, 0};
    UInt32 rymRPM[2]{4500, 4500};
    UInt32 ryrRPM[2]{2400, 2400};
    bool *wmiFullSpeedMirror = nullptr;

    IOReturn validateObject(const char *name) {
        if (!strcmp(name, "RYFS")) return hasRYFS ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYFF")) return hasRYFF ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYFA")) return hasRYFA ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYVW")) return hasRYVW ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYFM")) return hasRYFM ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYG0") || !strcmp(name, "RYG1")) return hasRYG ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYM0") || !strcmp(name, "RYM1")) return hasRYM ? kIOReturnSuccess : kIOReturnUnsupported;
        if (!strcmp(name, "RYR0") || !strcmp(name, "RYR1")) return hasRYR ? kIOReturnSuccess : kIOReturnUnsupported;
        return kIOReturnUnsupported;
    }

    IOReturn evaluateInteger(const char *name, UInt32 *out, void *args = nullptr, unsigned count = 0) override {
        if (transportError != kIOReturnSuccess)
            return transportError;
        if (!strcmp(name, "RYVW")) {
            if (!hasRYVW) return kIOReturnUnsupported;
            if (out) *out = verifiedWrites;
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYFA")) {
            if (!hasRYFA) return kIOReturnUnsupported;
            ++ryfaCalls;
            ryfmMask = 0;
            rygRPM[0] = rygRPM[1] = 0;
            if (out) *out = 0;
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYFM")) {
            if (!hasRYFM) return kIOReturnUnsupported;
            if (out) *out = ryfmMask;
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYG0")) {
            if (!hasRYG) return kIOReturnUnsupported;
            if (out) *out = rygRPM[0];
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYG1")) {
            if (!hasRYG) return kIOReturnUnsupported;
            if (out) *out = rygRPM[1];
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYM0")) {
            if (!hasRYM) return kIOReturnUnsupported;
            if (out) *out = rymRPM[0];
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYM1")) {
            if (!hasRYM) return kIOReturnUnsupported;
            if (out) *out = rymRPM[1];
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYR0")) {
            if (!hasRYR) return kIOReturnUnsupported;
            if (out) *out = ryrRPM[0];
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYR1")) {
            if (!hasRYR) return kIOReturnUnsupported;
            if (out) *out = ryrRPM[1];
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYFF") && count == 1 && args) {
            if (!hasRYFF) return kIOReturnUnsupported;
            auto **arr = static_cast<OSObject **>(args);
            UInt32 val = static_cast<UInt32>(static_cast<OSNumber *>(arr[0])->value);
            if (val) ++ryffOnCalls; else ++ryffOffCalls;
            if (wmiFullSpeedMirror) *wmiFullSpeedMirror = (val != 0);
            if (out) *out = 0;
            return kIOReturnSuccess;
        }
        if (!strcmp(name, "RYFS") && count == 2 && args) {
            if (!hasRYFS) return kIOReturnUnsupported;
            ++ryfsCalls;
            auto **arr = static_cast<OSObject **>(args);
            lastRyfsFan = static_cast<UInt32>(static_cast<OSNumber *>(arr[0])->value);
            lastRyfsRPM = static_cast<UInt32>(static_cast<OSNumber *>(arr[1])->value);
            if (verifiedWrites == 0) {
                if (out) *out = 1; // Matches SSDT-ReYoga RYFS: If (!RYVW ()) { Return (One) }
                return kIOReturnSuccess;
            }
            if (lastRyfsFan <= 1) {
                ryfmMask |= (1U << lastRyfsFan);
                rygRPM[lastRyfsFan] = lastRyfsRPM;
            }
            if (out) *out = 0;
            return kIOReturnSuccess;
        }
        return kIOReturnUnsupported;
    }
};

struct IdeaWMIGameZone {
    bool fullFan = false;
    bool setFullSpeedFails = false;
    bool getFullSpeedSupported = true;
    UInt32 smartFanMode = 2;
    unsigned setFullOnCalls = 0;
    unsigned setFullOffCalls = 0;
    unsigned setSmartFanCalls = 0;
    void (*onSmartFanSwitch)(UInt32 newMode) = nullptr;

    bool setFanFullSpeed(bool full) {
        if (setFullSpeedFails) return false;
        fullFan = full;
        if (full) ++setFullOnCalls; else ++setFullOffCalls;
        return true;
    }
    bool getFanFullSpeed(bool *enabled) {
        if (!getFullSpeedSupported || !enabled) return false;
        *enabled = fullFan;
        return true;
    }
    bool getGameZoneData(UInt32 query, UInt32 *out) {
        if (query == GAME_ZONE_WMI_GET_SMARTFAN_MODE && out) { *out = smartFanMode; return true; }
        return false;
    }
    bool setGameZoneData(UInt32 query, UInt32 value) {
        if (query == GAME_ZONE_WMI_SET_SMARTFAN_MODE) {
            smartFanMode = value;
            ++setSmartFanCalls;
            if (onSmartFanSwitch) onSmartFanSwitch(value);
            return true;
        }
        return false;
    }
    bool getPowerLimit(UInt32, UInt32[4]) { return false; }
    bool setPowerLimit(UInt32, UInt32) { return false; }
};

class ReYogaSMCUserClient;

class ReYogaVPC : public IOService {
public:
    Gate gate{this};
    Gate *commandGate = &gate;
    bool stopping = false;
    bool inactive = false;
    ReYogaSMCUserClient *client{nullptr};
    ReYogaSMCUserClient *openedClient{nullptr};

    bool isInactive() const { return inactive; }
    bool isOpen(const ReYogaSMCUserClient *uc) const { return openedClient == uc; }
    bool open(ReYogaSMCUserClient *uc) {
        if (openedClient && openedClient != uc) return false;
        openedClient = uc;
        return true;
    }
    void close(ReYogaSMCUserClient *uc) {
        if (openedClient == uc) openedClient = nullptr;
    }

    virtual IOReturn accessPlatformFan(UInt32 fan, UInt32 request, UInt8 output[3]) = 0;
    virtual IOReturn accessPlatformFanCurve(UInt32 fan, UInt32 request, UInt8 output[3]) = 0;
    virtual IOReturn readPlatformFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control) = 0;
    virtual void restorePlatformFans() = 0;
    virtual void restoreUserControls() = 0;
    virtual OSObject *getProperty(const char *) { return nullptr; }

    IOReturn accessThinkFanCurve(UInt32 fan, UInt32 request, UInt8 output[3]);
    IOReturn accessThinkFan(UInt32 fan, UInt32 request, UInt8 output[3]);
    IOReturn readThinkFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control = nullptr);
    void restoreThinkFans();

    // Stubbed unused legacy EC read methods for UserClient compilation
    IOReturn method_re1b(UInt32, UInt8 *) { return kIOReturnUnsupported; }
    IOReturn method_recb(UInt32, UInt32, void *) { return kIOReturnUnsupported; }
};

class IdeaVPC : public ReYogaVPC {
public:
    using super = ReYogaVPC;
    IOTimerEventSource timer;
    IOTimerEventSource pollerTimer;
    IOTimerEventSource *legionFanWatchdog = &timer;
    IOTimerEventSource *telemetryPoller = &pollerTimer;
    ReYogaControl::ThinkFanLease legionFanLease;

    MockEC mockEC;
    MockEC *ec = &mockEC;
    IOService *vpc = &mockEC;
    ReYogaNativeProfile verifiedProfile{
        "legion-verified-test",
        "Lenovo Legion Verified Test Fixture",
        "CB-01",
        "82N6",
        "GKCN",
        {"\\_SB.PCI0.LPC0.EC0.FANS", "\\_SB.PCI0.LPC0.EC0.FA2S", "\\_SB.PCI0.LPC0.EC0.CPUT", "\\_SB.PCI0.LPC0.EC0.GPUT"},
        {100, 100, 1, 1},
        "17aa:3a58",
        2,
        0xFE00D400ULL,
        0x600U,
        10U,
        1U
    };
    const ReYogaNativeProfile *nativeProfile = &verifiedProfile;
    IdeaWMIGameZone mockWMI;
    IdeaWMIGameZone *wmig = &mockWMI;

    bool safeMode = false;
    bool dual = true;
    bool telemetryAwake = true;
    bool legionBridge = false;
    UInt32 legionBridgeVersion = 0;
    bool dsdtMMIOVerified = true;
    bool fullSpeedEngaged = false;
    bool fullFanProperty = false;
    UInt8 capturedPowerMode = 0;
    UInt32 activeTargetRPM[2]{0, 0};
    bool powerLimitsSaved = false;
    UInt32 powerLimitsProfile = 0;
    UInt32 originalPowerLimits[2]{0, 0};
    UInt32 telemetryIntervalMS = 500;
    bool conservationMode = false;
    bool rapidChargeMode = false;
    unsigned warnings = 0;
    UInt8 activeFanControl[2]{0x84, 0x84};
    OSDictionary featureDict;
    OSDictionary featureEntry;

    UInt8 mockMMIO[0x600]{};
    volatile UInt8 *mmioBase = mockMMIO;
    IOPhysicalAddress mmioPhysBase = 0xFE00D400ULL;
    IOByteCount mmioSize = 0x600;
    bool ignoreLockClear = false;
    bool corruptWriteOffset = false;

    struct LegionCurvePoint {
        UInt8 upperTemp{0x7F};
        UInt8 lowerTemp{0x7F};
        UInt16 fan1RPM{0};
        UInt16 fan2RPM{0};
        UInt8 accel{2};
        UInt8 decel{2};
    };
    struct LegionFanCurveTable {
        UInt8 pointCount{10};
        LegionCurvePoint points[10];
    };

    LegionFanCurveTable factoryCurveTable{};
    LegionFanCurveTable activeCurveTable{};
    bool factoryCurveCaptured{false};
    bool customFanCurveActive{false};

    IdeaVPC() {
        mockEC.wmiFullSpeedMirror = &mockWMI.fullFan;
        featureEntry.isLeaf = true;
        featureDict.child = &featureEntry;
    }

    OSObject *getProperty(const char *key) override {
        if (!strcmp(key, "SafeMode")) return safeMode ? kOSBooleanTrue : nullptr;
        if (!strcmp(key, "Dual fan")) return dual ? kOSBooleanTrue : nullptr;
        if (!strcmp(key, fullFanPrompt)) return fullFanProperty ? kOSBooleanTrue : nullptr;
        if (!strcmp(key, "FeatureStatus")) return &featureDict;
        return nullptr;
    }
    void setProperty(const char *key, const char *) { if (!strcmp(key, "ThinkFanStatus")) ++warnings; }
    void setProperty(const char *key, UInt32, unsigned) { (void)key; }
    void setProperty(const char *, bool) {}
    void removeProperty(const char *) {}

    UInt8 readMMIO8(UInt32 offset) {
        if (mmioBase && offset < mmioSize) return mmioBase[offset];
        return 0;
    }
    UInt16 readMMIO16(UInt32 offset) {
        if (mmioBase && mmioSize >= 2 && offset < mmioSize - 1)
            return static_cast<UInt16>(mmioBase[offset]) | (static_cast<UInt16>(mmioBase[offset + 1]) << 8);
        return 0;
    }
    void writeMMIO8(UInt32 offset, UInt8 value) {
        if (mmioBase && offset < mmioSize && !safeMode) {
            if (ignoreLockClear && offset == kLegionRegLockFan && value == 0x00)
                return;
            if (corruptWriteOffset && offset == kLegionRegFan1Base) {
                mmioBase[offset] = 0x05;
                return;
            }
            mmioBase[offset] = value;
        }
    }

    bool restorePowerLimits() { return true; }
    void updateFeatureStatus() {}
    void updateTelemetry() {}
    IOReturn setBridgeFan(UInt32, UInt32) { return kIOReturnUnsupported; }
    bool setAlwaysOnUSBState(UInt32) { return false; }
    bool setUserBacklight(UInt32) { return false; }
    bool updateBattery(bool) { return false; }
    bool toggleConservation() { return false; }
    bool toggleRapidCharge() { return false; }
    bool setYLogo(bool) { return false; }
    bool setPortLighting(bool) { return false; }
    bool setFnLock(bool) { return false; }

    bool hasVerifiedLegionCurveProfile() const;
    bool isLegionFanCurveSupported() const;
    bool validateFanCurveTable(const LegionFanCurveTable &table, bool isRestoration = false, bool allowFactoryTemps = false) const;
    bool captureFactoryCurveTable();
    IOReturn applyLegionFanCurveTable(const LegionFanCurveTable &table, bool isRestoration = false, bool allowFactoryTemps = false);
    IOReturn readbackLegionFanCurveTable(LegionFanCurveTable &table);
    IOReturn engageFullSpeed();
    IOReturn disengageFullSpeed();
    IOReturn readHardwareFanControl(UInt32 fan, UInt8 &controlOut);
    IOReturn accessPlatformFanCurve(UInt32 fan, UInt32 requested, UInt8 output[3]) override;
    void expireLegionFanCurve(OSObject *, IOTimerEventSource *);
    IOReturn accessPlatformFan(UInt32 fan, UInt32 requested, UInt8 output[3]) override;
    IOReturn accessLegionFanGated(UInt32 fan, UInt32 requested, UInt8 output[3]);
    void restorePlatformFans() override;
    IOReturn restorePlatformFansGated(bool ecReloadedCurve = false);
    IOReturn readPlatformFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control) override;
    IOReturn setPowerStateGated(unsigned long state, IOService *device);
    void restoreUserControls() override;
    IOReturn setControl(const char *key, OSObject *value);
};

struct IOExternalMethodArguments {
    UInt32 scalarInputCount{0};
    UInt64 scalarInput[4]{};
    const void *structureInput{nullptr};
    UInt32 structureInputSize{0};
    void *structureOutput{nullptr};
    UInt32 structureOutputSize{0};
};

using IOExternalMethodAction = IOReturn (*)(OSObject *, void *, IOExternalMethodArguments *);
struct IOExternalMethodDispatch {
    IOExternalMethodAction function;
    UInt32 checkScalarInputCount;
    UInt32 checkStructureInputSize;
    UInt32 checkScalarOutputCount;
    UInt32 checkStructureOutputSize;
};

struct IOUserClient : OSObject {
    bool inactive{false};
    bool terminated{false};
    bool isInactive() const { return inactive; }
    void terminate() { terminated = true; }
    virtual IOReturn externalMethod(uint32_t, IOExternalMethodArguments *arguments,
                                    IOExternalMethodDispatch *dispatch, OSObject *target, void *reference) {
        if (!dispatch || !dispatch->function) return kIOReturnUnsupported;
        if (arguments->scalarInputCount != dispatch->checkScalarInputCount) return kIOReturnBadArgument;
        if (dispatch->checkStructureInputSize != 0 && arguments->structureInputSize != dispatch->checkStructureInputSize)
            return kIOReturnBadArgument;
        if (dispatch->checkStructureOutputSize != 0 && arguments->structureOutputSize < dispatch->checkStructureOutputSize)
            return kIOReturnBadArgument;
        return dispatch->function(target, reference, arguments);
    }
};

class ReYogaSMCUserClient : public IOUserClient {
public:
    struct MethodCall {
        ReYogaSMCUserClient *client;
        uint32_t selector;
        IOExternalMethodArguments *arguments;
    };
    enum class FanRequestMode { Direct, Watchdog };

    ReYogaVPC *provider_{nullptr};
    bool stopping_{false};
    bool administrator_{false};
    uint32_t ownerAuditToken_[kRYSMCAuditTokenWords]{};
    bool ownerAuditTokenValid_{false};
    bool fanAuthorized_{false};

    static IOExternalMethodDispatch kMethods[kRYSMCUCNumMethods];

    void clearNotificationGated() {}
    IOReturn readECGated(UInt64, UInt8 *, IOByteCount *) { return kIOReturnUnsupported; }

    static IOReturn methodReadEC(OSObject *, void *, IOExternalMethodArguments *) { return kIOReturnUnsupported; }
    static IOReturn methodWriteEC(OSObject *, void *, IOExternalMethodArguments *) { return kIOReturnUnsupported; }
    static IOReturn methodReadECName(OSObject *, void *, IOExternalMethodArguments *) { return kIOReturnUnsupported; }

    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *arguments,
                            IOExternalMethodDispatch *dispatch = nullptr, OSObject *target = nullptr, void *reference = nullptr);
    static IOReturn dispatchGated(OSObject *owner, void *arg0, void *, void *, void *);
    static IOReturn methodOpen(OSObject *target, void *, IOExternalMethodArguments *);
    static IOReturn methodClose(OSObject *target, void *, IOExternalMethodArguments *);
    static IOReturn methodThinkFan(OSObject *target, void *, IOExternalMethodArguments *arguments);
    static IOReturn methodThinkFanCurve(OSObject *target, void *, IOExternalMethodArguments *arguments);
    static IOReturn methodAuthorizeThinkFan(OSObject *target, void *, IOExternalMethodArguments *arguments);
    IOReturn openGated();
    IOReturn closeGated();
    static IOReturn closeGatedAction(OSObject *, void *arg0, void *, void *, void *);
    IOReturn thinkFanGated(UInt64 fan, UInt64 request, UInt8 *output, FanRequestMode mode);
    IOReturn clientClose();
    IOReturn clientDied();
};

IOExternalMethodDispatch ReYogaSMCUserClient::kMethods[kRYSMCUCNumMethods] = {
    {ReYogaSMCUserClient::methodOpen, 0, 0, 0, 0},
    {ReYogaSMCUserClient::methodClose, 0, 0, 0, 0},
    {ReYogaSMCUserClient::methodReadEC, 1, 0, 0, 1},
    {ReYogaSMCUserClient::methodWriteEC, 1, 0, 0, 0},
    {ReYogaSMCUserClient::methodReadECName, 0, 4, 0, 1},
    {ReYogaSMCUserClient::methodThinkFan, 2, 0, 0, kRYSMCFanReplySize},
    {ReYogaSMCUserClient::methodThinkFanCurve, 2, 0, 0, kRYSMCFanReplySize},
    {ReYogaSMCUserClient::methodAuthorizeThinkFan, 0, kRYSMCAuditTokenWords * sizeof(uint32_t), 0, 0},
};

// PRODUCTION_INJECTIONS

static void seedECFactoryCurve(IdeaVPC &dev, UInt8 pointCount, const UInt8 *uTemps, const UInt8 *lTemps, const UInt16 *speeds) {
    std::memset(dev.mockMMIO, 0, sizeof(dev.mockMMIO));
    dev.mockMMIO[kLegionRegPowerMode] = 2; // Balance
    dev.mockMMIO[kLegionRegCurveSize] = pointCount;
    for (UInt8 i = 0; i < pointCount; ++i) {
        dev.mockMMIO[kLegionRegFan1Base + i] = static_cast<UInt8>(speeds[i] / 100);
        dev.mockMMIO[kLegionRegFan2Base + i] = static_cast<UInt8>(speeds[i] / 100);
        dev.mockMMIO[kLegionRegCPUTemp + i] = uTemps[i];
        dev.mockMMIO[kLegionRegCPUTempHyst + i] = lTemps[i];
    }
    for (UInt8 i = pointCount; i < 10; ++i) {
        dev.mockMMIO[kLegionRegCPUTemp + i] = 0x7F;
        dev.mockMMIO[kLegionRegCPUTempHyst + i] = 0x7F;
    }
    dev.mockMMIO[kLegionRegFan1RPM] = 0x60;
    dev.mockMMIO[kLegionRegFan1RPM + 1] = 0x09; // 2400 RPM
    dev.mockMMIO[kLegionRegFan2RPM] = 0x60;
    dev.mockMMIO[kLegionRegFan2RPM + 1] = 0x09; // 2400 RPM
    dev.factoryCurveCaptured = false;
    dev.customFanCurveActive = false;
    dev.fullSpeedEngaged = false;
    dev.mockWMI.fullFan = false;
    dev.activeFanControl[0] = 0x84;
    dev.activeFanControl[1] = 0x84;
    dev.activeTargetRPM[0] = 0;
    dev.activeTargetRPM[1] = 0;
}

static IOReturn callUC(ReYogaSMCUserClient &uc, UInt32 selector, UInt64 fan = 0, UInt64 req = 0,
                       UInt8 out[3] = nullptr, const void *structIn = nullptr, UInt32 structInSize = 0) {
    IOExternalMethodArguments args{};
    if (selector == kRYSMCUCThinkFan || selector == kRYSMCUCThinkFanCurve) {
        args.scalarInputCount = 2;
        args.scalarInput[0] = fan;
        args.scalarInput[1] = req;
        args.structureOutput = out;
        args.structureOutputSize = out ? kRYSMCFanReplySize : 0;
    } else if (selector == kRYSMCUCAuthorizeThinkFan) {
        args.structureInput = structIn;
        args.structureInputSize = structInSize;
    }
    return uc.externalMethod(selector, &args);
}

int main() {
    const UInt8 uTemps10[10] = {45, 52, 58, 64, 70, 76, 82, 88, 94, 100};
    const UInt8 lTemps10[10] = {38, 44, 50, 56, 62, 68, 74, 80, 86, 92};
    const UInt16 speeds10[10] = {1600, 1900, 2200, 2500, 2800, 3200, 3600, 4000, 4300, 4500};

    // --- 1. Profile Safety & DSDT AML Verification (Real ReYogaNativeProfiles[]) ---
    {
        IdeaVPC dev;
        constexpr size_t count = sizeof(ReYogaNativeProfiles) / sizeof(ReYogaNativeProfiles[0]);
        for (size_t i = 0; i < count; ++i) {
            dev.nativeProfile = &ReYogaNativeProfiles[i];
            dev.dsdtMMIOVerified = true;
            // All shipped profiles currently have verifiedWrites == 0 -> MUST fail closed
            assert(dev.hasVerifiedLegionCurveProfile() == false);
        }

        // Gen 7 (0xFE0B0400) & Gen 8 (0xFE0B0F00) & unmapped Legion fail closed even if verifiedWrites were flipped without matching DSDT
        std::vector<uint8_t> gen6Dsdt(128, 0);
        memcpy(gen6Dsdt.data(), "DSDT", 4);
        gen6Dsdt[4] = 128;
        const uint8_t eraxGen6[] = {0x5B, 0x80, 'E', 'R', 'A', 'X', 0x00, 0x0C, 0x00, 0xD4, 0x00, 0xFE};
        memcpy(gen6Dsdt.data() + 40, eraxGen6, sizeof(eraxGen6));

        ReYogaNativeProfile gen7Profile = dev.verifiedProfile;
        gen7Profile.id = "legion5-gen7-arh";
        gen7Profile.ecBase = 0xFE0B0400ULL;
        dev.nativeProfile = &gen7Profile;
        dev.dsdtMMIOVerified = ReYogaFirmware::hasSystemMemoryRegion(gen6Dsdt.data(), gen6Dsdt.size(), gen7Profile.ecBase);
        assert(dev.dsdtMMIOVerified == false);
        assert(dev.hasVerifiedLegionCurveProfile() == false);

        ReYogaNativeProfile gen8Profile = dev.verifiedProfile;
        gen8Profile.id = "legion-pro5-gen8-irx";
        gen8Profile.ecBase = 0xFE0B0F00ULL;
        dev.nativeProfile = &gen8Profile;
        dev.dsdtMMIOVerified = ReYogaFirmware::hasSystemMemoryRegion(gen6Dsdt.data(), gen6Dsdt.size(), gen8Profile.ecBase);
        assert(dev.dsdtMMIOVerified == false);
        assert(dev.hasVerifiedLegionCurveProfile() == false);

        ReYogaNativeProfile noEcBaseProfile = dev.verifiedProfile;
        noEcBaseProfile.ecBase = 0;
        noEcBaseProfile.ecSize = 0;
        dev.nativeProfile = &noEcBaseProfile;
        dev.dsdtMMIOVerified = true;
        assert(dev.hasVerifiedLegionCurveProfile() == false);

        // Verified profile WITH matching DSDT AML passes
        dev.nativeProfile = &dev.verifiedProfile;
        dev.dsdtMMIOVerified = ReYogaFirmware::hasSystemMemoryRegion(gen6Dsdt.data(), gen6Dsdt.size(), dev.verifiedProfile.ecBase);
        assert(dev.dsdtMMIOVerified == true);
        assert(dev.hasVerifiedLegionCurveProfile() == true);
        assert(dev.isLegionFanCurveSupported() == true);

        // If legionBridge is active and RYVW != 1, fails closed
        dev.legionBridge = true;
        dev.legionBridgeVersion = 2;
        dev.mockEC.verifiedWrites = 0;
        assert(dev.hasVerifiedLegionCurveProfile() == false);
        dev.mockEC.verifiedWrites = 1;
        assert(dev.hasVerifiedLegionCurveProfile() == true);
    }

    // --- 2. Real UserClient ABI Dispatch & Authorization (kRYSMCUCAuthorizeThinkFan) ---
    IdeaVPC device;
    seedECFactoryCurve(device, 10, uTemps10, lTemps10, speeds10);

    ReYogaSMCUserClient appClient;
    appClient.provider_ = &device;
    appClient.administrator_ = false;
    for (UInt32 i = 0; i < kRYSMCAuditTokenWords; ++i)
        appClient.ownerAuditToken_[i] = 0xA000U + i;
    appClient.ownerAuditTokenValid_ = true;

    ReYogaSMCUserClient rootBroker;
    rootBroker.provider_ = &device;
    rootBroker.administrator_ = true;

    assert(callUC(appClient, kRYSMCUCOpen) == kIOReturnSuccess);
    device.client = &appClient;

    UInt8 output[3]{};
    // Unauthorized appClient can query RPM (selector 5, kRYSMCFanQueryRPM), but CANNOT write fan or curve
    assert(callUC(appClient, kRYSMCUCThinkFan, 0, kRYSMCFanQueryRPM, output) == kIOReturnSuccess);
    assert((output[0] | (output[1] << 8)) == 2400 && output[2] == 0x84);
    assert(callUC(appClient, kRYSMCUCThinkFan, 0, 5, output) == kIOReturnNotPermitted);
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 5, output) == kIOReturnNotPermitted);

    // Wrong audit token rejected
    UInt32 wrongToken[kRYSMCAuditTokenWords]{};
    assert(callUC(rootBroker, kRYSMCUCAuthorizeThinkFan, 0, 0, nullptr, wrongToken, sizeof(wrongToken)) == kIOReturnNotPermitted);
    assert(appClient.fanAuthorized_ == false);

    // Non-admin cannot authorize
    appClient.administrator_ = false;
    assert(callUC(appClient, kRYSMCUCAuthorizeThinkFan, 0, 0, nullptr, appClient.ownerAuditToken_, sizeof(appClient.ownerAuditToken_)) == kIOReturnNotPermitted);

    // Root broker with matching audit token authorizes appClient
    assert(callUC(rootBroker, kRYSMCUCAuthorizeThinkFan, 0, 0, nullptr, appClient.ownerAuditToken_, sizeof(appClient.ownerAuditToken_)) == kIOReturnSuccess);
    assert(appClient.fanAuthorized_ == true);

    // --- 3. Genuine EC 10-Point Curve Programming & Readback via UserClient Selector 6 ---
    nowMS = 1000;
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 5, output) == kIOReturnSuccess);
    assert(output[2] == 5);
    assert(device.customFanCurveActive == true);
    assert(device.mockMMIO[kLegionRegLockFan] == 0x00); // Lock register NEVER set to 0x08!
    assert(device.mockMMIO[kLegionRegCounter1] == 0x00);
    assert(device.mockMMIO[kLegionRegCounter2] == 0x00);
    assert(device.mockMMIO[kLegionRegMiniCurveCool] == 0xA0);
    assert(device.mockMMIO[kLegionRegCurveSize] == 10);
    // Every active point on fan 0 must be >= targetRPM (3500) and never lower factory points (4000, 4300, 4500)
    assert(device.mockMMIO[kLegionRegFan1Base + 0] == 35);
    assert(device.mockMMIO[kLegionRegFan1Base + 6] == 36);
    assert(device.mockMMIO[kLegionRegFan1Base + 9] == 45);
    // Fan 1 must remain at factory speeds
    assert(device.mockMMIO[kLegionRegFan2Base + 0] == 16);

    // Verify readHardwareFanControl detects external EC reversion (no RAM echoing!)
    device.mockMMIO[kLegionRegFan1Base + 0] = 16; // Reverted externally
    assert(callUC(appClient, kRYSMCUCThinkFan, 0, kRYSMCFanQueryRPM, output) == kIOReturnSuccess);
    assert(output[2] == 0x84); // Hardware readback reports 0x84, NOT stale RAM activeFanControl[0]!

    // Readback mismatch on write triggers automatic restoration & returns error
    device.corruptWriteOffset = true;
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 5, output) == kIOReturnIOError);
    device.corruptWriteOffset = false;
    assert(device.restorePlatformFansGated() == kIOReturnSuccess);
    assert(device.customFanCurveActive == false);
    assert(device.activeFanControl[0] == 0x84);

    // --- 4. RYFS Error when verified_writes == 0 (NEVER fake kIOReturnSuccess!) ---
    {
        IdeaVPC bridgeDev;
        seedECFactoryCurve(bridgeDev, 10, uTemps10, lTemps10, speeds10);
        bridgeDev.mmioBase = nullptr; // ACPI bridge path without MMIO
        bridgeDev.legionBridge = true;
        bridgeDev.legionBridgeVersion = 2;
        bridgeDev.mockEC.hasRYFS = true;
        bridgeDev.mockEC.hasRYFF = true;
        bridgeDev.mockEC.hasRYFA = true;
        bridgeDev.mockEC.hasRYVW = true;
        bridgeDev.mockEC.hasRYFM = true;
        bridgeDev.mockEC.hasRYG = true;
        bridgeDev.mockEC.hasRYM = true;
        bridgeDev.mockEC.verifiedWrites = 0;

        UInt8 out[3]{0xAA, 0xAA, 0xAA};
        assert(bridgeDev.accessPlatformFanCurve(0, 5, out) != kIOReturnSuccess);
        assert(bridgeDev.accessPlatformFan(0, 5, out) != kIOReturnSuccess);
        assert(out[2] == 0xAA); // Output untouched on failure

        // Now enable verifiedWrites == 1 on RYVW -> succeeds with readback verification
        bridgeDev.mockEC.verifiedWrites = 1;
        assert(bridgeDev.accessPlatformFanCurve(0, 5, out) == kIOReturnSuccess);
        assert(bridgeDev.mockEC.ryfsCalls >= 1);
        assert(out[2] == 5);

        // Transport error must fail closed
        bridgeDev.mockEC.transportError = kIOReturnIOError;
        assert(bridgeDev.accessPlatformFanCurve(0, 6, out) == kIOReturnIOError);
        bridgeDev.mockEC.transportError = kIOReturnSuccess;
        assert(bridgeDev.restorePlatformFansGated() == kIOReturnSuccess);
    }

    // --- 5. Full Speed (0x47) Step-Down 0x47 -> 5 Disengages RYFF(0) / setFanFullSpeed(false) ---
    {
        IdeaVPC fsDev;
        seedECFactoryCurve(fsDev, 10, uTemps10, lTemps10, speeds10);
        fsDev.legionBridge = true;
        fsDev.legionBridgeVersion = 2;
        fsDev.mockEC.hasRYFF = true;
        fsDev.mockEC.hasRYFA = true;
        fsDev.mockEC.hasRYVW = true;
        fsDev.mockEC.verifiedWrites = 1;

        UInt8 out[3]{};
        nowMS = 1000;
        assert(fsDev.accessPlatformFanCurve(0, 0x47, out) == kIOReturnSuccess);
        assert(out[2] == 0x47);
        assert(fsDev.mockEC.ryffOnCalls == 1);
        assert(fsDev.mockWMI.fullFan == true);
        assert(fsDev.fullSpeedEngaged == true);

        // Step down 0x47 -> 5: MUST call RYFF(0) / disengageFullSpeed()
        nowMS = 2000;
        assert(fsDev.accessPlatformFanCurve(0, 5, out) == kIOReturnSuccess);
        assert(out[2] == 5);
        assert(fsDev.mockEC.ryffOffCalls == 1);
        assert(fsDev.mockWMI.fullFan == false);
        assert(fsDev.fullSpeedEngaged == false);
        assert(fsDev.mockMMIO[kLegionRegFan1Base] == 35);

        assert(fsDev.restorePlatformFansGated() == kIOReturnSuccess);
    }

    // --- 6. Partial Lease Expiration (Curve Preservation & Global 0x47 Latch Safety) ---
    {
        IdeaVPC partialDev;
        seedECFactoryCurve(partialDev, 10, uTemps10, lTemps10, speeds10);
        partialDev.legionBridge = true;
        partialDev.legionBridgeVersion = 2;
        partialDev.mockEC.hasRYFF = true;
        partialDev.mockEC.hasRYFA = true;
        partialDev.mockEC.hasRYVW = true;
        partialDev.mockEC.verifiedWrites = 1;

        UInt8 out[3]{};
        // 6a. Fan 0 at level 4 (t=0), Fan 1 at level 7 (t=1000) -> Fan 0 expires at t=6000 leaving Fan 1 at 7
        nowMS = 0;
        assert(partialDev.accessPlatformFanCurve(0, 4, out) == kIOReturnSuccess);
        assert(partialDev.mockMMIO[kLegionRegFan1Base] == 31);
        nowMS = 1000;
        assert(partialDev.accessPlatformFanCurve(1, 7, out) == kIOReturnSuccess);
        assert(partialDev.mockMMIO[kLegionRegFan2Base] == 45);

        nowMS = 6000;
        partialDev.expireLegionFanCurve(nullptr, nullptr);
        assert(partialDev.activeFanControl[0] == 0x84);
        assert(partialDev.activeFanControl[1] == 7);
        assert(partialDev.mockMMIO[kLegionRegFan1Base] == 16); // Fan 0 restored to factory
        assert(partialDev.mockMMIO[kLegionRegFan2Base] == 45); // Fan 1 preserved
        assert(partialDev.mockMMIO[kLegionRegLockFan] == 0x00);
        assert(partialDev.legionFanLease.active() == true);

        nowMS = 7000;
        partialDev.expireLegionFanCurve(nullptr, nullptr);
        assert(partialDev.activeFanControl[0] == 0x84);
        assert(partialDev.activeFanControl[1] == 0x84);
        assert(partialDev.mockMMIO[kLegionRegFan2Base] == 16);
        assert(partialDev.mockMMIO[kLegionRegLockFan] == 0x00);
        assert(partialDev.legionFanLease.active() == false);
        assert(partialDev.timer.enabled == false);

        // 6b. Fan 0 at level 4 (t=10000), Fan 1 at 0x47 (t=11000) -> Fan 0 expires at t=16000 without disengaging Fan 1's 0x47!
        nowMS = 10000;
        assert(partialDev.accessPlatformFanCurve(0, 4, out) == kIOReturnSuccess);
        nowMS = 11000;
        assert(partialDev.accessPlatformFanCurve(1, 0x47, out) == kIOReturnSuccess);
        assert(partialDev.mockEC.ryffOnCalls == 1);

        nowMS = 16000;
        partialDev.expireLegionFanCurve(nullptr, nullptr);
        assert(partialDev.mockEC.ryffOffCalls == 0); // Fan 1 still holds 0x47!
        assert(partialDev.fullSpeedEngaged == true);
        assert(partialDev.mockWMI.fullFan == true);
        assert(partialDev.activeFanControl[0] == 0x84);
        assert(partialDev.activeFanControl[1] == 0x47);
        assert(partialDev.mockMMIO[kLegionRegFan1Base] == 16); // Fan 0 curve restored to factory
        assert(partialDev.mockMMIO[kLegionRegLockFan] == 0x00);
        assert(partialDev.legionFanLease.active() == true);

        // While Fan 1 holds global 0x47, Fan 0 requesting level 5 fails closed rather than silently returning fake level 5
        assert(partialDev.accessPlatformFanCurve(0, 5, out) == kIOReturnBusy);

        // At t=17000: Fan 1 expires -> RYFF(0) disengages!
        nowMS = 17000;
        partialDev.expireLegionFanCurve(nullptr, nullptr);
        assert(partialDev.mockEC.ryffOffCalls == 1);
        assert(partialDev.fullSpeedEngaged == false);
        assert(partialDev.mockWMI.fullFan == false);
        assert(partialDev.activeFanControl[0] == 0x84);
        assert(partialDev.activeFanControl[1] == 0x84);
        assert(partialDev.legionFanLease.active() == false);
        assert(partialDev.timer.enabled == false);
    }

    // --- 7. Short Factory Curve (pointCount = 8) Capture & Restoration ---
    {
        IdeaVPC shortDev;
        const UInt8 uTemps8[8] = {45, 52, 58, 64, 70, 76, 82, 98};
        const UInt8 lTemps8[8] = {38, 44, 50, 56, 62, 68, 74, 90};
        const UInt16 speeds8[8] = {1600, 1900, 2200, 2500, 2800, 3200, 3600, 4200};
        seedECFactoryCurve(shortDev, 8, uTemps8, lTemps8, speeds8);
        // Simulate uninitialized/garbage bytes in EC inactive slots 8..9
        shortDev.mockMMIO[kLegionRegCPUTemp + 8] = 0x00;
        shortDev.mockMMIO[kLegionRegCPUTemp + 9] = 0x00;
        shortDev.mockMMIO[kLegionRegFan1Base + 8] = 0x10;

        assert(shortDev.captureFactoryCurveTable() == true);
        assert(shortDev.factoryCurveTable.pointCount == 8);
        assert(shortDev.factoryCurveTable.points[8].upperTemp == 0x7F);
        assert(shortDev.factoryCurveTable.points[8].fan1RPM == 0);
        assert(shortDev.validateFanCurveTable(shortDev.factoryCurveTable, true) == true);

        UInt8 out[3]{};
        nowMS = 1000;
        assert(shortDev.accessPlatformFanCurve(0, 5, out) == kIOReturnSuccess);
        assert(shortDev.mockMMIO[kLegionRegCurveSize] == 8);
        assert(shortDev.mockMMIO[kLegionRegCPUTemp + 8] == 0x7F);
        assert(shortDev.mockMMIO[kLegionRegFan1Base + 8] == 0);
        assert(shortDev.restorePlatformFansGated() == kIOReturnSuccess);
        assert(shortDev.mockMMIO[kLegionRegFan1Base] == 16);
        assert(shortDev.mockMMIO[kLegionRegCPUTemp + 7] == 98);
    }

    // --- 8. Tachometer Underrun (0xFFFF / >= 20000) Propagates Error ---
    {
        UInt32 rpm = 999;
        UInt8 ctrl = 0;

        // Valid RPM
        device.mockMMIO[kLegionRegFan1RPM] = 0x80;
        device.mockMMIO[kLegionRegFan1RPM + 1] = 0x0C; // 3200 RPM
        assert(device.readPlatformFanRPM(0, rpm, &ctrl) == kIOReturnSuccess);
        assert(rpm == 3200 && ctrl == 0x84);
        assert(callUC(appClient, kRYSMCUCThinkFan, 0, kRYSMCFanQueryRPM, output) == kIOReturnSuccess);
        assert((output[0] | (output[1] << 8)) == 3200);

        // Overflow >= 20000 RPM -> kIOReturnUnderrun
        device.mockMMIO[kLegionRegFan1RPM] = 0x20;
        device.mockMMIO[kLegionRegFan1RPM + 1] = 0x4E; // 20000 RPM
        assert(device.readPlatformFanRPM(0, rpm, &ctrl) == kIOReturnUnderrun);
        assert(rpm == 0);
        assert(callUC(appClient, kRYSMCUCThinkFan, 0, kRYSMCFanQueryRPM, output) == kIOReturnUnderrun);

        // Disconnected sensor 0xFFFF -> kIOReturnUnderrun, NOT 0 RPM + kIOReturnSuccess!
        device.mockMMIO[kLegionRegFan1RPM] = 0xFF;
        device.mockMMIO[kLegionRegFan1RPM + 1] = 0xFF;
        assert(device.readPlatformFanRPM(0, rpm, &ctrl) == kIOReturnUnderrun);
        assert(rpm == 0);
        assert(callUC(appClient, kRYSMCUCThinkFan, 0, kRYSMCFanQueryRPM, output) == kIOReturnUnderrun);

        // Restore valid RPM for subsequent tests
        device.mockMMIO[kLegionRegFan1RPM] = 0x60;
        device.mockMMIO[kLegionRegFan1RPM + 1] = 0x09;
    }

    // --- 9. Real UserClient clientClose() / clientDied() Immediate Fallback ---
    nowMS = 2000;
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 5, output) == kIOReturnSuccess);
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 1, 6, output) == kIOReturnSuccess);
    assert(device.customFanCurveActive == true);
    assert(device.legionFanLease.active() == true);

    nowMS = 2500;
    assert(appClient.clientClose() == kIOReturnSuccess);
    assert(appClient.terminated == true);
    assert(device.activeFanControl[0] == 0x84);
    assert(device.activeFanControl[1] == 0x84);
    assert(device.customFanCurveActive == false);
    assert(device.legionFanLease.active() == false);
    assert(device.mockMMIO[kLegionRegLockFan] == 0x00);
    assert(device.mockMMIO[kLegionRegFan1Base] == 16);
    assert(device.timer.enabled == false);

    // Re-open and test clientDied()
    appClient.stopping_ = false;
    appClient.terminated = false;
    assert(callUC(appClient, kRYSMCUCOpen) == kIOReturnSuccess);
    assert(callUC(rootBroker, kRYSMCUCAuthorizeThinkFan, 0, 0, nullptr, appClient.ownerAuditToken_, sizeof(appClient.ownerAuditToken_)) == kIOReturnSuccess);
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 4, output) == kIOReturnSuccess);
    assert(device.customFanCurveActive == true);
    assert(appClient.clientDied() == kIOReturnSuccess);
    assert(device.activeFanControl[0] == 0x84);
    assert(device.customFanCurveActive == false);
    assert(device.legionFanLease.active() == false);

    // --- 10. Real Power State Sleep/Wake & SmartFanMode Switch (SPMO ROM Curve Preservation) ---
    appClient.stopping_ = false;
    appClient.terminated = false;
    assert(callUC(appClient, kRYSMCUCOpen) == kIOReturnSuccess);
    assert(callUC(rootBroker, kRYSMCUCAuthorizeThinkFan, 0, 0, nullptr, appClient.ownerAuditToken_, sizeof(appClient.ownerAuditToken_)) == kIOReturnSuccess);
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 5, output) == kIOReturnSuccess);
    assert(device.setPowerStateGated(0, &device) == kIOReturnSuccess);
    assert(device.telemetryAwake == false);
    assert(device.activeFanControl[0] == 0x84);
    assert(device.customFanCurveActive == false);
    assert(device.legionFanLease.active() == false);
    assert(device.setPowerStateGated(1, &device) == kIOReturnSuccess);
    assert(device.telemetryAwake == true);
    assert(device.activeFanControl[0] == 0x84);

    // Real IdeaVPC::setControl("SmartFanMode", 3): simulates BIOS reloading Performance ROM curve (2000 RPM floor)
    static IdeaVPC *gSmartFanDev = nullptr;
    gSmartFanDev = &device;
    device.mockWMI.onSmartFanSwitch = [](UInt32 newMode) {
        gSmartFanDev->mockMMIO[kLegionRegPowerMode] = static_cast<UInt8>(newMode);
        gSmartFanDev->mockMMIO[kLegionRegFan1Base] = 20; // Performance mode ROM curve = 2000 RPM
    };
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 5, output) == kIOReturnSuccess);
    assert(device.mockMMIO[kLegionRegFan1Base] == 35);
    OSNumber *modeTarget = OSNumber::withNumber(3ULL, 32);
    assert(device.setControl("SmartFanMode", modeTarget) == kIOReturnSuccess);
    modeTarget->release();
    // New Performance mode ROM curve (20 = 2000 RPM) must NOT be overwritten by old Balance curve (16 = 1600 RPM)!
    assert(device.mockMMIO[kLegionRegFan1Base] == 20);
    assert(device.factoryCurveCaptured == false);
    assert(device.customFanCurveActive == false);
    assert(device.activeFanControl[0] == 0x84);
    assert(device.legionFanLease.active() == false);

    // --- 11. SafeMode & Invalid Inputs Fail Closed ---
    device.safeMode = true;
    assert(callUC(appClient, kRYSMCUCThinkFan, 0, 4, output) == kIOReturnNotPermitted);
    assert(callUC(appClient, kRYSMCUCThinkFanCurve, 0, 4, output) == kIOReturnNotPermitted);
    assert(callUC(appClient, kRYSMCUCOpen) == kIOReturnSuccess);
    assert(callUC(appClient, kRYSMCUCClose) == kIOReturnSuccess);
    assert(device.accessPlatformFanCurve(0, 4, output) == kIOReturnUnsupported);
    assert(device.accessPlatformFan(0, 4, output) == kIOReturnUnsupported);
    device.mockMMIO[kLegionRegFan1Base] = 0x16;
    device.writeMMIO8(kLegionRegFan1Base, 0x40);
    assert(device.mockMMIO[kLegionRegFan1Base] == 0x16);
    device.safeMode = false;

    assert(device.accessPlatformFanCurve(0, 7, nullptr) == kIOReturnBadArgument);
    assert(device.accessPlatformFanCurve(2, 7, output) == kIOReturnBadArgument);
    assert(device.accessPlatformFanCurve(0, 0, output) == kIOReturnBadArgument);
    assert(device.accessPlatformFanCurve(0, 8, output) == kIOReturnBadArgument);
    assert(device.accessPlatformFanCurve(0, 0x84, output) == kIOReturnBadArgument);
    assert(device.accessPlatformFan(0, 0, output) == kIOReturnNotPermitted);
    assert(device.accessPlatformFan(0, 8, output) == kIOReturnBadArgument);

    return 0;
}
'''.replace('// PRODUCTION_INJECTIONS', prod_code)

        with tempfile.TemporaryDirectory() as directory:
            compat_mach = pathlib.Path(directory) / 'compat' / 'mach'
            compat_mach.mkdir(parents=True)
            (compat_mach / 'message.h').write_text(
                '#ifndef COMPAT_MACH_MESSAGE_H\n'
                '#define COMPAT_MACH_MESSAGE_H\n'
                'typedef struct { unsigned int msgh_bits, msgh_size, msgh_remote_port, msgh_local_port, msgh_voucher_port; int msgh_id; } mach_msg_header_t;\n'
                '#endif\n',
                encoding='utf-8',
            )
            source = pathlib.Path(directory) / 'legion_curve_test.cpp'
            source.write_text(fixture, encoding='utf-8')
            executable = pathlib.Path(directory) / 'legion_curve_test.exe'
            compiler = shutil.which('g++') or shutil.which('clang++')
            build = subprocess.run([compiler, '-std=c++14', '-Wall', '-Wextra', '-Werror',
                                    '-I', str(ROOT), '-idirafter', str(pathlib.Path(directory) / 'compat'),
                                    str(source), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=30)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run_result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run_result.returncode, 0, run_result.stdout + run_result.stderr)


if __name__ == '__main__':
    unittest.main()
