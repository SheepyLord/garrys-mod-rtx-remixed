"""Execute the shipping HL2 RTX viewmodel hooks; no game or native DLL required."""
from pathlib import Path
import unittest

try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime = None


SOURCE = (Path(__file__).resolve().parents[1] / 'garrysmod/garrysmod/addons/mount-hl2rtx'
          '/lua/autorun/client/hl2rtx_model_compat_viewmodels.lua')
REFRESH = 'HL2RTXModelCompat_Refresh'
PISTOL = 'models/weapons/v_pistol.mdl'


class Harness:
    def __init__(self, mounted=False, missing=()):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(r'''
            mounted=false; marker_reads=0; model_checks=0; precaches=0; set_calls=0
            in_render=false; invalid_models={}; convars={}; hooks={}; commands={}; timers={}; deferred={}; logs={}
            string.Replace=function(s,a,b) return (s:gsub(a,b)) end
            IsValid=function(entity) return type(entity)=='table' and entity.valid==true end
            CreateClientConVar=function(name,default)
                local cv={value=default}
                function cv:GetBool() return self.value=='1' end
                convars[name]=cv
                return cv
            end
            file={Exists=function(path,root)
                assert(not in_render,'filesystem query in rendering')
                assert(path=='.rtxlauncher-hl2rtx-overlay.json' and root=='GAME')
                marker_reads=marker_reads+1
                return mounted
            end}
            util={IsValidModel=function(model)
                assert(not in_render,'model validity query in rendering')
                model_checks=model_checks+1
                return invalid_models[model]~=true
            end,PrecacheModel=function(model)
                assert(not in_render,'model precache in rendering')
                assert(invalid_models[model]~=true,'missing model precached')
                precaches=precaches+1
            end}
            timer={Create=function(name,delay,count,fn)
                assert(delay==0 and count==1,'only one-shot refresh is allowed')
                timers[name]={fn=fn,delay=delay,count=count}
            end,Remove=function(name)timers[name]=nil end,
                Simple=function(delay,fn) assert(delay==0) deferred[#deferred+1]=fn end}
            hook={Add=function(event,name,fn)
                hooks[event]=hooks[event] or {};hooks[event][name]=fn
            end}
            concommand={Add=function(name,fn)commands[name]=fn end}
            print=function(text)logs[#logs+1]=text end
            weapon={valid=true,class='weapon_physgun'}
            function weapon:GetClass()return self.class end
            vm={valid=true,model='models/weapons/c_pistol.mdl'}
            function vm:GetModel()return self.model end
            function vm:GetOwner()return player end
            function vm:SetWeaponModel(model,owner)
                assert(owner==weapon)
                set_calls=set_calls+1
                if not reject_set then self.model=model end
                local change=hooks.OnViewModelChanged and hooks.OnViewModelChanged.HL2RTXModelCompat_CombinedViewModelChanged
                if change then change(self) end
            end
            hands={valid=true,GetModel=function()return 'models/weapons/c_arms.mdl' end}
            player={valid=true}
            function player:GetActiveWeapon()return weapon end
            function player:GetViewModel(index)assert(index==0)return vm end
            function player:GetHands()return hands end
            LocalPlayer=function()return player end
            function draw()
                in_render=true
                hooks.PreDrawViewModel.HL2RTXModelCompat_CombinedViewModel(vm,player,weapon)
                local hidden=hooks.PreDrawPlayerHands.HL2RTXModelCompat_HideSeparateHands(hands,vm,player,weapon)
                in_render=false
                return hidden
            end
            function drawHands()
                in_render=true
                local hidden=hooks.PreDrawPlayerHands.HL2RTXModelCompat_HideSeparateHands(hands,vm,player,weapon)
                in_render=false
                return hidden
            end
        ''')
        self.lua.globals().mounted = mounted
        for model in missing:
            self.lua.globals().invalid_models[model] = True
        self.lua.execute(SOURCE.read_text(encoding='utf8'))

    @property
    def g(self):
        return self.lua.globals()

    def event(self, event):
        for fn in self.g.hooks[event].values():
            fn()

    def refresh(self):
        self.g.commands['hl2rtx_model_compat_refresh']()

    def drain(self):
        timer = self.g.timers[REFRESH]
        if timer:
            timer.fn()
        self.assert_no_timer()

    def assert_no_timer(self):
        assert self.g.timers[REFRESH] is None


@unittest.skipIf(LuaRuntime is None, 'lupa is required to execute the actual client hooks')
class ViewmodelCacheTests(unittest.TestCase):
    def test_unmounted_and_unmapped_rendering_never_queries_filesystem_or_models(self):
        for mounted in (False, True):
            with self.subTest(mounted=mounted):
                h = Harness(mounted)
                before = (h.g.marker_reads, h.g.model_checks, h.g.precaches)
                for weapon in ('weapon_physgun', 'gmod_tool', 'custom_weapon'):
                    h.g.weapon['class'] = weapon
                    h.lua.execute('for i=1,1000 do assert(draw()==nil) end')
                h.lua.execute("weapon={valid=false,GetClass=function()error('invalid weapon class read')end};draw();weapon=nil;draw()")
                self.assertEqual((h.g.marker_reads, h.g.model_checks, h.g.precaches), before)
                self.assertEqual(h.g.set_calls, 0)
                h.assert_no_timer()
                if not mounted:
                    self.assertEqual(before, (1, 0, 0))

    def test_mapped_replacement_is_applied_once_and_hands_follow_actual_model(self):
        h = Harness(True)
        self.assertEqual((h.g.marker_reads, h.g.model_checks, h.g.precaches), (1, 12, 12))
        h.g.weapon['class'] = 'WeApOn_PiStOl'
        self.assertIsNone(h.g.drawHands(), 'valid replacement alone must not hide separate hands')
        self.assertTrue(h.g.draw())
        self.assertEqual(h.g.vm.model, PISTOL)
        h.lua.execute('for i=1,1000 do assert(draw()==true) end')
        self.assertEqual(h.g.set_calls, 1)
        self.assertEqual((h.g.marker_reads, h.g.model_checks, h.g.precaches), (1, 12, 12))
        self.assertEqual(len(h.g.deferred), 0, 'SetWeaponModel recursion should not queue another override')
        h.g.vm.valid = False
        self.assertIsNone(h.g.drawHands())

    def test_missing_models_are_negatively_cached_and_never_hide_hands(self):
        h = Harness(True, missing=(PISTOL,))
        h.g.weapon['class'] = 'weapon_pistol'
        h.lua.execute('for i=1,1000 do assert(draw()==nil) end')
        self.assertEqual(h.g.set_calls, 0)
        self.assertEqual((h.g.marker_reads, h.g.model_checks, h.g.precaches), (1, 12, 11))
        # Even an existing same-named viewmodel is not sufficient after invalidation.
        h.g.vm.model = PISTOL
        self.assertIsNone(h.g.drawHands())
        h.g.invalid_models[PISTOL] = None
        self.assertIsNone(h.g.drawHands(), 'a negative result remains cached until an explicit lifecycle refresh')
        h.refresh()
        self.assertTrue(h.g.drawHands())

    def test_failed_substitution_keeps_separate_hands_visible(self):
        h = Harness(True)
        h.g.weapon['class'] = 'weapon_pistol'
        h.g.reject_set = True
        self.assertIsNone(h.g.draw())
        self.assertEqual(h.g.vm.model, 'models/weapons/c_pistol.mdl')
        self.assertIsNone(h.g.drawHands())

    def test_content_changes_invalidate_immediately_and_refresh_once_per_burst(self):
        h = Harness(True)
        h.g.weapon['class'] = 'weapon_pistol'
        self.assertTrue(h.g.draw())
        h.g.mounted = False
        for _ in range(20):
            h.event('GameContentChanged')
        self.assertIsNone(h.g.drawHands())
        self.assertEqual(h.g.marker_reads, 1)
        h.drain()
        self.assertEqual((h.g.marker_reads, h.g.model_checks), (2, 12))
        self.assertIsNone(h.g.draw())
        h.g.mounted = True
        h.event('GameContentChanged')
        self.assertIsNone(h.g.draw())
        h.drain()
        self.assertTrue(h.g.draw())
        self.assertEqual((h.g.marker_reads, h.g.model_checks), (3, 24))

    def test_initially_absent_mount_can_appear_on_each_documented_refresh_path(self):
        for event in ('InitPostEntity', 'GameContentChanged', 'OnReloaded', 'explicit'):
            with self.subTest(event=event):
                h = Harness()
                h.g.weapon['class'] = 'weapon_pistol'
                self.assertIsNone(h.g.draw())
                h.g.mounted = True
                if event == 'explicit':
                    h.refresh()
                else:
                    h.event(event)
                    self.assertIsNone(h.g.draw())
                    h.drain()
                self.assertTrue(h.g.draw())
                self.assertEqual((h.g.marker_reads, h.g.model_checks), (2, 12))
                h.assert_no_timer()

    def test_explicit_refresh_cancels_pending_refresh_and_revalidates_missing_model(self):
        h = Harness(True)
        h.g.weapon['class'] = 'weapon_pistol'
        self.assertTrue(h.g.draw())
        h.g.invalid_models[PISTOL] = True
        h.event('GameContentChanged')
        h.refresh()
        h.assert_no_timer()
        self.assertEqual(h.g.marker_reads, 2)
        self.assertIsNone(h.g.drawHands())

    def test_enabled_toggle_and_debug_status_preserve_behavior_without_filesystem_queries(self):
        h = Harness(True)
        h.g.weapon['class'] = 'weapon_pistol'
        h.g.convars['hl2rtx_model_compat_combined_viewmodels'].value = '0'
        self.assertIsNone(h.g.draw())
        h.g.convars['hl2rtx_model_compat_combined_viewmodels'].value = '1'
        h.g.convars['hl2rtx_model_compat_debug'].value = '1'
        self.assertTrue(h.g.draw())
        self.assertEqual(len(h.g.logs), 1)
        h.g.vm.model = 'models/weapons/c_pistol.mdl'
        self.assertTrue(h.g.draw())
        self.assertEqual(len(h.g.logs), 1, 'identical diagnostic must remain deduplicated')
        h.g.commands['hl2rtx_model_compat_status']()
        self.assertIn('  mounted (cached): true', list(h.g.logs.values()))
        self.assertIn('  replacement valid: true', list(h.g.logs.values()))
        self.assertEqual((h.g.marker_reads, h.g.model_checks), (1, 12))

    def test_weapon_switch_and_viewmodel_change_defer_and_recheck_active_entities(self):
        h = Harness(True)
        h.g.weapon['class'] = 'weapon_pistol'
        switch = h.g.hooks['PlayerSwitchWeapon']['HL2RTXModelCompat_CombinedViewModelSwitch']
        switch(h.g.player, None, h.g.weapon)
        self.assertEqual(h.g.set_calls, 0)
        h.g.deferred[1]()
        self.assertEqual(h.g.set_calls, 1)
        h.g.vm.model = 'models/weapons/c_pistol.mdl'
        change = h.g.hooks['OnViewModelChanged']['HL2RTXModelCompat_CombinedViewModelChanged']
        change(h.g.vm)
        h.g.player.valid = False
        h.g.deferred[2]()
        self.assertEqual(h.g.set_calls, 1)
        self.assertEqual((h.g.marker_reads, h.g.model_checks), (1, 12))


if __name__ == '__main__':
    unittest.main()
