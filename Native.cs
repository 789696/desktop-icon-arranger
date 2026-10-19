using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DeskNative
{
    public const uint LVM_FIRST = 0x1000;
    public const uint LVM_GETITEMCOUNT = LVM_FIRST + 4;      // 0x1004
    public const uint LVM_SETITEMPOSITION = LVM_FIRST + 15;  // 0x100F
    public const uint LVM_GETITEMPOSITION = LVM_FIRST + 16;  // 0x1010
    public const uint LVM_GETITEMSPACING = LVM_FIRST + 51;   // 0x1033
    public const uint LVM_GETITEMTEXTW = LVM_FIRST + 115;    // 0x1073

    [StructLayout(LayoutKind.Sequential)]
    public struct LVITEM
    {
        public uint mask; public int iItem; public int iSubItem; public uint state; public uint stateMask;
        public IntPtr pszText; public int cchTextMax; public int iImage; public IntPtr lParam;
        public int iIndent; public int iGroupId; public uint cColumns; public IntPtr puColumns;
        public IntPtr piColFmt; public int iGroup;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindow(string cls, string win);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string win);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern bool InvalidateRect(IntPtr hWnd, IntPtr r, bool erase);
    [DllImport("user32.dll")]
    public static extern bool UpdateWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    // The desktop SysListView32 and the monitor rectangles only share one
    // coordinate space when this process is per-monitor DPI aware.  With plain
    // "system" awareness a 200% primary monitor makes GetSystemMetrics report a
    // virtual desktop twice as wide as the list view really is, and icons land
    // in the wrong place.  Per-monitor-v2 is therefore the correct mode; fall
    // back to the old call on Windows versions that do not know it.
    public static void EnableBestDpiAwareness()
    {
        try { if (SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)) return; }
        catch { }
        try { SetProcessDPIAware(); }
        catch { }
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int StrCmpLogicalW(string a, string b);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, out RECT pvParam, uint fWinIni);

    public const uint SPI_GETWORKAREA = 0x0030;

    // Primary monitor work area (screen minus taskbar and appbars), physical pixels.
    public static int[] GetWorkArea()
    {
        RECT r;
        if (SystemParametersInfo(SPI_GETWORKAREA, 0, out r, 0))
            return new int[] { r.left, r.top, r.right, r.bottom };
        return null;
    }

    // ------------------------------------------------------------- monitors
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;

    // Every monitor in physical virtual-desktop pixels:
    //   { monLeft, monTop, monRight, monBottom, workLeft, workTop, workRight, workBottom, isPrimary }
    public static int[][] GetMonitors()
    {
        List<int[]> list = new List<int[]>();
        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data)
        {
            MONITORINFO mi = new MONITORINFO();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(hMon, ref mi))
            {
                list.Add(new int[] {
                    mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right, mi.rcMonitor.bottom,
                    mi.rcWork.left, mi.rcWork.top, mi.rcWork.right, mi.rcWork.bottom,
                    (mi.dwFlags & 1) != 0 ? 1 : 0
                });
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        list.Sort(delegate(int[] a, int[] b) { return a[0] != b[0] ? a[0] - b[0] : a[1] - b[1]; });
        return list.ToArray();
    }

    // Bounding box of the whole virtual desktop in physical pixels: { left, top, right, bottom }.
    public static int[] GetVirtualRect()
    {
        int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (w <= 0 || h <= 0) return null;
        return new int[] { x, y, x + w, y + h };
    }

    // Effective DPI of each monitor.  Used to scale the icon grid: a 96-DPI
    // monitor uses a grid half as wide as the same layout on a 192-DPI monitor.
    //   { monLeft, monTop, dpiX, dpiY, hresult }
    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    public static int[][] GetMonitorDpis()
    {
        List<int[]> list = new List<int[]>();
        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data)
        {
            uint dx = 0, dy = 0;
            int hr = -1;
            try { hr = GetDpiForMonitor(hMon, 0, out dx, out dy); }
            catch { }
            list.Add(new int[] { rc.left, rc.top, (int)dx, (int)dy, hr });
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        list.Sort(delegate(int[] a, int[] b) { return a[0] != b[0] ? a[0] - b[0] : a[1] - b[1]; });
        return list.ToArray();
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProc, IntPtr addr, uint size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualFreeEx(IntPtr hProc, IntPtr addr, uint size, uint type);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProc, IntPtr addr, byte[] buf, uint size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(IntPtr hProc, IntPtr addr, byte[] buf, uint size, out IntPtr read);
    [DllImport("kernel32.dll")]
    public static extern uint GetLastError();

    public static IntPtr FindDesktopListView()
    {
        IntPtr defView = IntPtr.Zero;
        IntPtr progman = FindWindow("Progman", null);
        if (progman != IntPtr.Zero)
            defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);

        if (defView == IntPtr.Zero)
        {
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                IntPtr dv = FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (dv != IntPtr.Zero) { defView = dv; return false; }
                return true;
            }, IntPtr.Zero);
        }
        if (defView == IntPtr.Zero) return IntPtr.Zero;
        return FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
    }
}

public class DesktopView : IDisposable
{
    const uint MEM_COMMIT_RESERVE = 0x3000;
    const uint PAGE_READWRITE = 0x04;
    const int TEXT_OFFSET = 1024;
    const int TEXT_BYTES = 1040;

    public IntPtr ListView;
    public IntPtr Process;
    IntPtr remote;

    public DesktopView()
    {
        ListView = DeskNative.FindDesktopListView();
        if (ListView == IntPtr.Zero) throw new Exception("desktop SysListView32 not found");
        uint pid;
        DeskNative.GetWindowThreadProcessId(ListView, out pid);
        Process = DeskNative.OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (Process == IntPtr.Zero) throw new Exception("OpenProcess failed, win32 error " + Marshal.GetLastWin32Error());
        remote = DeskNative.VirtualAllocEx(Process, IntPtr.Zero, 4096, MEM_COMMIT_RESERVE, PAGE_READWRITE);
        if (remote == IntPtr.Zero) throw new Exception("VirtualAllocEx failed, win32 error " + Marshal.GetLastWin32Error());
    }

    public void Dispose()
    {
        if (remote != IntPtr.Zero) { DeskNative.VirtualFreeEx(Process, remote, 0, 0x8000); remote = IntPtr.Zero; }
        if (Process != IntPtr.Zero) { DeskNative.CloseHandle(Process); Process = IntPtr.Zero; }
    }

    IntPtr RemoteAt(int offset) { return new IntPtr(remote.ToInt64() + offset); }

    public int Count
    {
        get { return (int)DeskNative.SendMessage(ListView, DeskNative.LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero); }
    }

    public int[] Spacing
    {
        get
        {
            long r = DeskNative.SendMessage(ListView, DeskNative.LVM_GETITEMSPACING, IntPtr.Zero, IntPtr.Zero).ToInt64();
            return new int[] { (int)(r & 0xFFFF), (int)((r >> 16) & 0xFFFF) };
        }
    }

    public int[] ClientSize
    {
        get
        {
            DeskNative.RECT rc;
            DeskNative.GetClientRect(ListView, out rc);
            return new int[] { rc.right - rc.left, rc.bottom - rc.top };
        }
    }

    public int[] WindowRect
    {
        get
        {
            DeskNative.RECT rc;
            DeskNative.GetWindowRect(ListView, out rc);
            return new int[] { rc.left, rc.top, rc.right, rc.bottom };
        }
    }

    public string GetName(int index)
    {
        DeskNative.LVITEM it = new DeskNative.LVITEM();
        it.mask = 0x0001;
        it.iItem = index;
        it.iSubItem = 0;
        it.pszText = RemoteAt(TEXT_OFFSET);
        it.cchTextMax = 260;

        int size = Marshal.SizeOf(typeof(DeskNative.LVITEM));
        IntPtr local = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(it, local, false);
            byte[] raw = new byte[size];
            Marshal.Copy(local, raw, 0, size);
            IntPtr written;
            if (!DeskNative.WriteProcessMemory(Process, remote, raw, (uint)size, out written))
                throw new Exception("WriteProcessMemory failed, win32 error " + Marshal.GetLastWin32Error());

            DeskNative.SendMessage(ListView, DeskNative.LVM_GETITEMTEXTW, new IntPtr(index), remote);

            byte[] txt = new byte[TEXT_BYTES];
            IntPtr got;
            if (!DeskNative.ReadProcessMemory(Process, RemoteAt(TEXT_OFFSET), txt, (uint)txt.Length, out got))
                throw new Exception("ReadProcessMemory failed, win32 error " + Marshal.GetLastWin32Error());

            string s = Encoding.Unicode.GetString(txt);
            int z = s.IndexOf('\0');
            return z >= 0 ? s.Substring(0, z) : s;
        }
        finally { Marshal.FreeHGlobal(local); }
    }

    public int[] GetPosition(int index)
    {
        DeskNative.SendMessage(ListView, DeskNative.LVM_GETITEMPOSITION, new IntPtr(index), remote);
        byte[] b = new byte[8];
        IntPtr got;
        DeskNative.ReadProcessMemory(Process, remote, b, 8, out got);
        return new int[] { BitConverter.ToInt32(b, 0), BitConverter.ToInt32(b, 4) };
    }

    public void SetPosition(int index, int x, int y)
    {
        int packed = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
        DeskNative.SendMessage(ListView, DeskNative.LVM_SETITEMPOSITION, new IntPtr(index), new IntPtr(packed));
    }

    public void Refresh()
    {
        DeskNative.InvalidateRect(ListView, IntPtr.Zero, true);
        DeskNative.UpdateWindow(ListView);
    }
}
