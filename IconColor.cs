using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class IconColorInfo
{
    public string ShellPath;
    public bool Found;
    public double Hue = -1;          // dominant hue 0-360, -1 when neutral
    public double Colorfulness = 0;  // fraction of opaque pixels that are saturated
    public double Lightness = 0;     // mean HSL lightness of opaque pixels
    public int R, G, B;              // mean RGB of opaque pixels
    public string Error = "";
}

public static class IconColorAnalyzer
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);
    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr hIcon);

    const uint SHGFI_ICON = 0x100;
    const uint SHGFI_LARGEICON = 0x0;

    public static IconColorInfo Analyze(string shellPath)
    {
        IconColorInfo res = new IconColorInfo();
        res.ShellPath = shellPath;
        SHFILEINFO info = new SHFILEINFO();
        IntPtr ok = SHGetFileInfo(shellPath, 0, ref info, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), SHGFI_ICON | SHGFI_LARGEICON);
        if (ok == IntPtr.Zero || info.hIcon == IntPtr.Zero)
        {
            res.Error = "no icon";
            return res;
        }
        try
        {
            using (Icon ic = Icon.FromHandle(info.hIcon))
            using (Bitmap bmp = ic.ToBitmap())
            {
                int w = bmp.Width, h = bmp.Height;
                double[] hist = new double[36];
                long opaque = 0, colored = 0;
                double sumL = 0, sumR = 0, sumG = 0, sumB = 0;
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++)
                    {
                        Color c = bmp.GetPixel(x, y);
                        if (c.A < 40) continue;
                        opaque++;
                        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
                        double max = Math.Max(r, Math.Max(g, b));
                        double min = Math.Min(r, Math.Min(g, b));
                        double l = (max + min) / 2.0;
                        double d = max - min;
                        double s = (d == 0) ? 0 : (l > 0.5 ? d / (2 - max - min) : d / (max + min));
                        sumL += l; sumR += c.R; sumG += c.G; sumB += c.B;
                        if (s >= 0.25 && max >= 0.20)
                        {
                            double hue;
                            if (max == r) hue = 60 * (((g - b) / d) % 6);
                            else if (max == g) hue = 60 * (((b - r) / d) + 2);
                            else hue = 60 * (((r - g) / d) + 4);
                            if (hue < 0) hue += 360;
                            int bin = (int)(hue / 10.0) % 36;
                            hist[bin] += s * (0.35 + 0.65 * max);
                            colored++;
                        }
                    }
                }
                if (opaque == 0) { res.Error = "fully transparent"; return res; }
                res.Found = true;
                res.Colorfulness = (double)colored / opaque;
                res.Lightness = sumL / opaque;
                res.R = (int)(sumR / opaque); res.G = (int)(sumG / opaque); res.B = (int)(sumB / opaque);

                if (res.Colorfulness >= 0.08)
                {
                    // find peak bin with circular smoothing
                    int peak = 0; double best = -1;
                    for (int i = 0; i < 36; i++)
                    {
                        double v = hist[(i + 35) % 36] * 0.5 + hist[i] * 2 + hist[(i + 1) % 36] * 0.5;
                        if (v > best) { best = v; peak = i; }
                    }
                    double wsum = 0, hsum = 0;
                    for (int k = -3; k <= 3; k++)
                    {
                        int i = ((peak + k) % 36 + 36) % 36;
                        // accumulate within a contiguous hue window around the peak
                        double centre = peak * 10 + 5;
                        double angle = i * 10 + 5;
                        double diff = angle - centre;
                        while (diff > 180) diff -= 360;
                        while (diff < -180) diff += 360;
                        if (Math.Abs(diff) > 35) continue;
                        wsum += hist[i];
                        hsum += hist[i] * (centre + diff);
                    }
                    res.Hue = wsum > 0 ? ((hsum / wsum) % 360 + 360) % 360 : peak * 10 + 5;
                }
                return res;
            }
        }
        catch (Exception ex) { res.Error = ex.Message; return res; }
        finally { DestroyIcon(info.hIcon); }
    }
}
