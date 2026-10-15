; Monitor Brightness Control (DDC/CI) + Gamma Screen Dimmer
; Left-click the tray icon (or Win+Alt+B) for the control panel.
;
;   Win+Alt+Up / Down      hardware brightness (DDC/CI, primary monitor)
;   Win+Alt+Left / Right   software dimmer (gamma, selected monitor(s))
;   Win+Alt+X              dimmer on/off
;   Win+Alt+F1..F4         scenes: Reading / Office / Movie / Night

#Requires AutoHotkey v2.0
#SingleInstance Force

; ───────────── Settings ─────────────
STEP        := 10                  ; hardware hotkey step (%)
DIM_STEP    := 5                   ; dimmer hotkey step (%)
PRESETS     := [25, 50, 75, 100]   ; hardware preset buttons (%)
THROTTLE_MS := 40                  ; min delay between DDC/CI writes while dragging

; Scenes: [dimmer %, blue-light filter %]
SCENES := Map("Reading", [75, 35]
            , "Office",  [90, 10]
            , "Movie",   [60, 25]
            , "Night",   [30, 60])

; Auto schedule (tray menu): blends DAY_SCENE <-> NIGHT_SCENE
DAY_START   := 7  * 60             ; minutes after midnight
NIGHT_START := 20 * 60
TRANSITION  := 60                  ; length of the fade, in minutes
DAY_SCENE   := "Office"
NIGHT_SCENE := "Night"

INI      := RegExReplace(A_ScriptFullPath, "\.\w+$", ".ini")
WIDE_KEY := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM"

; ───────────── Hardware brightness (dxva2 / DDC/CI) ─────────────
class Monitor {
    static handle  := 0     ; first physical monitor of the primary display
    static buf     := 0     ; PHYSICAL_MONITOR array (kept so it can be destroyed properly)
    static count   := 0
    static lo      := 0     ; raw min/max reported by the monitor
    static hi      := 100
    static percent := 50    ; last known brightness, 0-100
    static queued  := false

    ; Open the primary monitor. Only sleeps *between* failed attempts.
    static Open(retries := 3) {
        this.Close()
        loop retries {
            if this.TryOpen()
                return true
            this.Close()
            if A_Index < retries
                Sleep(200 * A_Index)
        }
        return false
    }

    static TryOpen() {
        hMon := DllCall("MonitorFromWindow", "Ptr", 0, "UInt", 1, "Ptr")   ; MONITOR_DEFAULTTOPRIMARY
        if !hMon
            return false
        if !DllCall("dxva2\GetNumberOfPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt*", &n := 0) || !n
            return false

        ; PHYSICAL_MONITOR = HANDLE + WCHAR[128] (packed)
        buf := Buffer((A_PtrSize + 256) * n, 0)
        if !DllCall("dxva2\GetPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt", n, "Ptr", buf)
            return false

        this.buf    := buf
        this.count  := n
        this.handle := NumGet(buf, 0, "Ptr")
        return this.handle && this.Read() != ""    ; verify the monitor really answers DDC/CI
    }

    static Close() {
        if this.handle
            DllCall("dxva2\DestroyPhysicalMonitors", "UInt", this.count, "Ptr", this.buf)
        this.handle := this.count := this.buf := 0
    }

    ; Returns brightness in % (and caches it), or "" on failure.
    static Read() {
        if !this.handle
            return ""
        if DllCall("dxva2\GetMonitorBrightness", "Ptr", this.handle
                , "UInt*", &lo := 0, "UInt*", &cur := 0, "UInt*", &hi := 0) {
            this.lo := lo, this.hi := hi
        } else if DllCall("dxva2\GetVCPFeatureAndVCPFeatureReply", "Ptr", this.handle
                , "UChar", 0x10, "Ptr", 0, "UInt*", &cur := 0, "UInt*", &hi := 0) {
            this.lo := 0, this.hi := hi            ; VCP 0x10 = luminance
        } else {
            return ""
        }
        return this.percent := Round((cur - this.lo) * 100 / Max(this.hi - this.lo, 1))
    }

    ; Write brightness immediately.
    static Apply() {
        if !this.handle
            return
        raw := this.lo + Round(this.percent * (this.hi - this.lo) / 100)
        if !DllCall("dxva2\SetMonitorBrightness", "Ptr", this.handle, "UInt", raw)
            DllCall("dxva2\SetVCPFeature", "Ptr", this.handle, "UChar", 0x10, "UInt", raw)
    }

    ; Set brightness (clamped) - rate-limited, safe to call on every slider tick.
    static Set(pct) {
        this.percent := Min(Max(Integer(pct), 0), 100)
        if !this.queued {
            this.queued := true
            SetTimer(this.Flush.Bind(this), -THROTTLE_MS)
        }
    }

    static Flush() {
        this.queued := false
        this.Apply()
    }
}

; ───────────── Software dimmer (GPU gamma ramp, no overlay) ─────────────
; Works like CareUEyes: the gamma ramp of each display is scaled, so the GPU
; outputs less light. Screenshots, fullscreen apps and PWM are unaffected.
class Dimmer {
    static n      := 0
    static dim    := []       ; per monitor, 1-100 (%)
    static warm   := []       ; per monitor, 0-100 (% blue-light filter)
    static target := 0        ; 0 = all monitors, otherwise monitor index
    static off    := false    ; dimmer bypassed
    static wide   := false    ; GdiIcmGammaRange registry key present
    static minDim := 50       ; lowest dim % Windows accepts
    static auto   := false
    static lastT  := -1
    static tickFn := 0

    static Init() {
        this.wide   := ReadWide()
        this.minDim := this.wide ? 1 : 50
        this.Resize()
        this.Load()
        this.Apply()
        if this.auto
            this.SetAuto(true)
        SetTimer(this.Reapply.Bind(this), 5000)   ; sleep/unlock/other apps can reset the ramp
    }

    static Resize() {
        n := MonitorGetCount()
        while this.dim.Length < n {
            this.dim.Push(100)
            this.warm.Push(0)
        }
        this.dim.Length  := n
        this.warm.Length := n
        this.n := n
        if this.target > n
            this.target := 0
    }

    static Reconfigure() {
        this.Resize()
        this.Apply()
    }

    static Targets() {
        if this.target
            return [this.target]
        list := []
        loop this.n
            list.Push(A_Index)
        return list
    }

    static Current() => this.target || 1

    static WakeUp() {
        if this.off {
            this.off := false
            A_TrayMenu.Check("Dimmer enabled")
        }
    }

    static Toggle() {
        this.off := !this.off
        this.Apply()
        if this.off
            A_TrayMenu.Uncheck("Dimmer enabled")
        else
            A_TrayMenu.Check("Dimmer enabled")
    }

    static SetDim(pct) {
        this.WakeUp()
        pct := Min(Max(Integer(pct), this.minDim), 100)
        for i in this.Targets()
            this.dim[i] := pct
        this.Apply()
    }

    static SetWarm(pct) {
        this.WakeUp()
        pct := Min(Max(Integer(pct), 0), 100)
        for i in this.Targets()
            this.warm[i] := pct
        this.Apply()
    }

    static Preset(name) {
        v := SCENES[name]
        this.WakeUp()
        for i in this.Targets() {
            this.dim[i]  := Min(Max(v[1], this.minDim), 100)
            this.warm[i] := v[2]
        }
        this.Apply()
    }

    static Active() {
        if this.off
            return false
        loop this.n {
            if this.dim[A_Index] < 100 || this.warm[A_Index] > 0
                return true
        }
        return false
    }

    static Reapply() {
        if this.Active()
            this.Apply()
    }

    ; ── gamma ──
    static Mult(i) {
        f := this.dim[i] / 100
        w := this.warm[i] / 100
        return [f, f * (1 - 0.28 * w), f * (1 - 0.62 * w)]     ; R, G, B
    }

    static Ramp(mult, lim) {
        buf := Buffer(1536, 0)                                  ; 3 x 256 WORDs
        loop 3 {
            c := A_Index - 1
            m := Max(mult[c + 1], lim)
            loop 256
                NumPut("UShort", Min(Round((A_Index - 1) * 257 * m), 65535), buf, c * 512 + (A_Index - 1) * 2)
        }
        return buf
    }

    static ApplyMonitor(i, identity := false) {
        try
            name := MonitorGetName(i)
        catch
            return false
        hdc := DllCall("gdi32\CreateDCW", "WStr", "DISPLAY", "WStr", name, "Ptr", 0, "Ptr", 0, "Ptr")
        if !hdc
            return false
        mult := (identity || this.off) ? [1, 1, 1] : this.Mult(i)
        ok := false
        ; Windows rejects ramps that are too dark; if so, back off step by step
        for lim in (this.wide ? [0.004, 0.25, 0.5, 0.75, 1] : [0.5, 0.65, 0.8, 1]) {
            if DllCall("gdi32\SetDeviceGammaRamp", "Ptr", hdc, "Ptr", this.Ramp(mult, lim), "Int") {
                ok := true
                break
            }
        }
        DllCall("gdi32\DeleteDC", "Ptr", hdc)
        return ok
    }

    static Apply() {
        loop this.n
            this.ApplyMonitor(A_Index)
    }

    static Restore() {
        loop this.n
            this.ApplyMonitor(A_Index, true)
    }

    ; ── auto schedule ──
    static SetAuto(on) {
        this.auto  := on
        this.lastT := -1
        if !this.tickFn
            this.tickFn := this.Tick.Bind(this)
        SetTimer(this.tickFn, on ? 30000 : 0)
        if on {
            A_TrayMenu.Check("Auto schedule (day/night)")
            this.Tick()
        } else {
            A_TrayMenu.Uncheck("Auto schedule (day/night)")
        }
    }

    static Tick() {
        t := NightFactor()
        if t = this.lastT                      ; only touch values when the fade moves,
            return                             ; so manual tweaks stick between fades
        this.lastT := t
        a := SCENES[DAY_SCENE], b := SCENES[NIGHT_SCENE]
        d := Min(Max(Round(a[1] + (b[1] - a[1]) * t), this.minDim), 100)
        w := Round(a[2] + (b[2] - a[2]) * t)
        this.off := false
        A_TrayMenu.Check("Dimmer enabled")
        loop this.n {
            this.dim[A_Index]  := d
            this.warm[A_Index] := w
        }
        this.Apply()
        if IsSet(flyout)
            flyout.Refresh()
    }

    ; ── persistence ──
    static Save() {
        d := "", w := ""
        loop this.n {
            d .= (d = "" ? "" : ",") . this.dim[A_Index]
            w .= (w = "" ? "" : ",") . this.warm[A_Index]
        }
        try {
            IniWrite(d, INI, "Dimmer", "dim")
            IniWrite(w, INI, "Dimmer", "warm")
            IniWrite(this.auto ? 1 : 0, INI, "Dimmer", "auto")
        }
    }

    static Load() {
        for i, v in StrSplit(IniRead(INI, "Dimmer", "dim", ""), ",")
            if IsInteger(v) && i <= this.n
                this.dim[i] := Min(Max(v, this.minDim), 100)
        for i, v in StrSplit(IniRead(INI, "Dimmer", "warm", ""), ",")
            if IsInteger(v) && i <= this.n
                this.warm[i] := Min(Max(v, 0), 100)
        this.auto := IniRead(INI, "Dimmer", "auto", "0") = "1"
    }
}

; ───────────── Control panel (built once, reused) ─────────────
class BrightnessFlyout {
    lastHide := 0

    __New() {
        g := this.gui := Gui("+AlwaysOnTop -Caption +ToolWindow +Border", "Brightness")
        g.BackColor := "2D2D30"
        g.SetFont("s10 cWhite", "Segoe UI")

        g.Add("Text", "x10 y10 w240 Center", "Gloam")
        close := g.Add("Text", "x260 y10 w30 h20 Center c0xFF4444 +0x100", "✕")
        close.SetFont("s12 Bold")
        close.OnEvent("Click", (*) => this.Hide())

        ; monitor selector (dimmer target)
        this.ddl := g.Add("DropDownList", "x20 y38 w260 cBlack", ["All Monitors"])
        this.ddl.OnEvent("Change", (c, *) => this.OnTarget(c.Value))

        ; hardware brightness (DDC/CI)
        r := this.AddRow(72, "Brightness (monitor)", "0-100", (c, *) => this.SetHw(c.Value))
        this.hwSlider := r[1], this.hwVal := r[2]
        g.SetFont("s9", "Segoe UI")
        for pct in PRESETS
            g.Add("Button", Format("x{} y126 w60 h26", 20 + (A_Index - 1) * 65), pct "%")
             .OnEvent("Click", this.HwPreset.Bind(this, pct))

        ; software dimmer + blue light
        g.SetFont("s10 cWhite", "Segoe UI")
        r := this.AddRow(164, "Dimmer", "1-100", (c, *) => this.SetDim(c.Value))
        this.dimSlider := r[1], this.dimVal := r[2]
        r := this.AddRow(220, "Blue light filter", "0-100", (c, *) => this.SetWarm(c.Value))
        this.warmSlider := r[1], this.warmVal := r[2]

        ; scenes
        g.SetFont("s9", "Segoe UI")
        for name in ["Reading", "Office", "Movie", "Night"]
            g.Add("Button", Format("x{} y278 w60 h28", 20 + (A_Index - 1) * 65), name)
             .OnEvent("Click", this.Scene.Bind(this, name))

        g.SetFont("s8 c909090", "Segoe UI")
        this.note := g.Add("Text", "x20 y312 w260 h28", "")

        g.OnEvent("Escape", (*) => this.Hide())
        g.Show("w300 h345 Hide")                                ; apply size without showing
        OnMessage(0x0006, ObjBindMethod(this, "OnActivate"))    ; WM_ACTIVATE: hide on focus loss
    }

    AddRow(y, caption, range, onChange) {
        g := this.gui
        g.Add("Text", Format("x20 y{} w180 cA0A0A0", y), caption)
        val := g.Add("Text", Format("x200 y{} w80 Right cFFFFFF", y), "")
        sl  := g.Add("Slider", Format("x20 y{} w260 h30 Range{} TickInterval10 Tooltip", y + 20, range))
        sl.OnEvent("Change", onChange)
        return [sl, val]
    }

    Toggle() {
        if DllCall("IsWindowVisible", "Ptr", this.gui.Hwnd)
            return this.Hide()
        if A_TickCount - this.lastHide < 300           ; the click that just dismissed us
            return

        if Monitor.handle || Monitor.Open(1)           ; dimmer still works without DDC/CI
            Monitor.Read()
        this.RebuildMonitorList()
        this.Refresh()

        ; Bottom-right of the primary work area (raw pixels, DPI-safe)
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        this.gui.GetPos(, , &w, &h)
        DllCall("SetWindowPos", "Ptr", this.gui.Hwnd, "Ptr", -1                ; HWND_TOPMOST
            , "Int", r - w - 12, "Int", b - h - 12, "Int", 0, "Int", 0
            , "UInt", 0x0001 | 0x0040)                                         ; NOSIZE | SHOWWINDOW
        WinActivate("ahk_id " this.gui.Hwnd)
    }

    Hide() {
        this.lastHide := A_TickCount
        this.gui.Hide()
        Dimmer.Save()
    }

    RebuildMonitorList() {
        items := ["All Monitors"]
        loop Dimmer.n
            items.Push(Format("Monitor {}{}", A_Index, A_Index = MonitorGetPrimary() ? " (primary)" : ""))
        this.ddl.Delete()
        this.ddl.Add(items)
        this.ddl.Choose(Dimmer.target + 1)
    }

    ; Sync all controls with current state (also safe while hidden)
    Refresh() {
        this.RefreshHw()
        this.RefreshDim()
    }

    RefreshHw() {
        if Monitor.handle {
            this.hwSlider.Enabled := true
            this.hwSlider.Value   := Monitor.percent
            this.hwVal.Value      := Monitor.percent "%"
        } else {
            this.hwSlider.Enabled := false
            this.hwVal.Value      := "N/A"
        }
    }

    RefreshDim() {
        i := Dimmer.Current()
        this.dimSlider.Value  := Dimmer.dim[i]
        this.dimVal.Value     := Dimmer.dim[i] "%"
        this.warmSlider.Value := Dimmer.warm[i]
        this.warmVal.Value    := Dimmer.warm[i] "%"
        this.note.Value := Dimmer.wide ? ""
            : "Dimmer floor is 50%. Tray menu > Wider dimming range unlocks 1%."
    }

    OnTarget(v) {
        Dimmer.target := v - 1
        this.RefreshDim()
    }

    SetHw(pct) {
        Monitor.Set(pct)
        this.hwVal.Value := Monitor.percent "%"
    }

    HwPreset(pct, *) {
        if !Monitor.handle
            return
        this.hwSlider.Value := pct
        this.SetHw(pct)
    }

    SetDim(pct) {
        Dimmer.SetDim(pct)
        this.RefreshDim()              ; also snaps the slider back if Windows' floor clamps it
    }

    SetWarm(pct) {
        Dimmer.SetWarm(pct)
        this.warmVal.Value := Dimmer.warm[Dimmer.Current()] "%"
    }

    Scene(name, *) {
        Dimmer.Preset(name)
        this.RefreshDim()
    }

    OnActivate(wParam, lParam, msg, hwnd) {
        if hwnd = this.gui.Hwnd && (wParam & 0xFFFF) = 0   ; WA_INACTIVE
            this.Hide()
    }
}

; ───────────── Helpers ─────────────
EnsureMonitor(showError := false) {
    if Monitor.handle || Monitor.Open()
        return true
    if showError
        MsgBox("Failed to initialize monitor.`n`nTroubleshooting:`n"
             . "1. Enable DDC/CI in the monitor's OSD menu`n"
             . "2. Try unplugging/replugging the monitor`n"
             . "3. Update graphics drivers", "Error", 0x10)
    return false
}

Toast(text) {
    ToolTip(text)
    SetTimer(ToolTip, -1000)       ; ToolTip() with no args clears it
}

Nudge(delta) {
    if !EnsureMonitor() {
        Toast("No DDC/CI monitor found")
        return
    }
    Monitor.Set(Monitor.percent + delta)
    flyout.Refresh()
    Toast("Brightness: " Monitor.percent "%")
}

NudgeDim(delta) {
    Dimmer.SetDim(Dimmer.dim[Dimmer.Current()] + delta)
    flyout.RefreshDim()
    Toast("Dimmer: " Dimmer.dim[Dimmer.Current()] "%")
}

ScenePreset(name) {
    Dimmer.Preset(name)
    flyout.RefreshDim()
    Toast("Scene: " name)
}

; 0 = full day, 1 = full night, fading over TRANSITION minutes
NightFactor() {
    m := A_Hour * 60 + A_Min
    sinceNight := Mod(m - NIGHT_START + 1440, 1440)
    sinceDay   := Mod(m - DAY_START + 1440, 1440)
    if sinceNight < TRANSITION
        return sinceNight / TRANSITION
    if sinceDay < TRANSITION
        return 1 - sinceDay / TRANSITION
    nightLen := Mod(DAY_START - NIGHT_START + 1440, 1440)
    return sinceNight < nightLen ? 1 : 0
}

; Windows only lets gamma ramps go down to ~50% unless this key exists (admin + reboot).
ReadWide() {
    try return RegRead(WIDE_KEY, "GdiIcmGammaRange") = 256
    return false
}

SetWide(enable) {
    try {
        if enable
            RegWrite(256, "REG_DWORD", WIDE_KEY, "GdiIcmGammaRange")
        else
            RegDelete(WIDE_KEY, "GdiIcmGammaRange")
    } catch as e {
        MsgBox("Could not change the registry:`n" e.Message, "Error", 0x10)
        ExitApp
    }
    MsgBox("Done. Restart Windows for the change to take effect,`nthen start this script again.", "Dimming range")
    ExitApp
}

ToggleWide(*) {
    enable := !Dimmer.wide
    if A_IsAdmin
        return SetWide(enable)
    text := enable
        ? "Unlock dimming down to 1%?`n`nThis sets a Windows registry value (needs administrator rights) and requires a restart."
        : "Go back to the default dimming range (50%)?`n`nThis needs administrator rights and a restart."
    if MsgBox(text, "Wider dimming range", "YesNo Icon?") = "Yes"
        try Run(Format('*RunAs "{}" "{}" {}', A_AhkPath, A_ScriptFullPath, enable ? "/widerange" : "/narrowrange"))
}

OnDisplayChange() {                    ; handles go stale when displays change
    Monitor.Close()
    Dimmer.Reconfigure()
}

; ───────────── Startup ─────────────
if A_Args.Length && (A_Args[1] = "/widerange" || A_Args[1] = "/narrowrange")
    SetWide(A_Args[1] = "/widerange")

TraySetIcon("shell32.dll", 175)
A_IconTip := "Brightness Control"

flyout := BrightnessFlyout()

A_TrayMenu.Delete()
A_TrayMenu.Add("Brightness Control", (*) => flyout.Toggle())
A_TrayMenu.Add()
A_TrayMenu.Add("Dimmer enabled", (*) => Dimmer.Toggle())
A_TrayMenu.Add("Auto schedule (day/night)", (*) => Dimmer.SetAuto(!Dimmer.auto))
A_TrayMenu.Add("Wider dimming range (admin + restart)", ToggleWide)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default    := "Brightness Control"
A_TrayMenu.ClickCount := 1                      ; single click opens the panel
A_TrayMenu.Check("Dimmer enabled")

Dimmer.Init()
if Dimmer.wide
    A_TrayMenu.Check("Wider dimming range (admin + restart)")

Monitor.Open(1)                                 ; quick silent attempt; retried on demand
OnExit((*) => (Dimmer.Save(), Dimmer.Restore(), Monitor.Close()))
OnMessage(0x007E, (*) => SetTimer(OnDisplayChange, -1500))   ; WM_DISPLAYCHANGE

; ───────────── Hotkeys (must stay at the end of the file) ─────────────
#!b::flyout.Toggle()          ; Win+Alt+B       toggle panel
#!Up::Nudge(STEP)             ; Win+Alt+Up      hardware brighter
#!Down::Nudge(-STEP)          ; Win+Alt+Down    hardware dimmer
#!Right::NudgeDim(DIM_STEP)   ; Win+Alt+Right   software brighter
#!Left::NudgeDim(-DIM_STEP)   ; Win+Alt+Left    software dimmer
#!x::Dimmer.Toggle()          ; Win+Alt+X       dimmer on/off
#!F1::ScenePreset("Reading")
#!F2::ScenePreset("Office")
#!F3::ScenePreset("Movie")
#!F4::ScenePreset("Night")
