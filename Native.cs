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
