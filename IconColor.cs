using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class IconColorInfo
{
    // ---- v1 fields (kept: still computed, used as diagnostics / fallback) ----
    public string ShellPath;
    public bool Found;
    public double Hue = -1;          // saturation-weighted dominant hue
    public double Colorfulness = 0;  // fraction of saturated pixels
    public double Lightness = 0;     // mean HSL lightness
    public int R, G, B;
    public string Error = "";

    // ---- v2 fields: area based voting + median colour ----
    public int MedR, MedG, MedB;     // median colour, per channel
    public double MedHue = -1, MedSat = 0, MedLight = 0;
    public double WhiteFrac, BlackFrac, GrayFrac;
    public double[] FamFrac = new double[7]; // red orange yellow green cyan blue purple
    public int TopFam;
    public double TopFamFrac;
    public double OpaquePixels;
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

    static void RgbToHsl(int r, int g, int b, out double h, out double s, out double l)
    {
        double rr = r / 255.0, gg = g / 255.0, bb = b / 255.0;
        double max = Math.Max(rr, Math.Max(gg, bb)), min = Math.Min(rr, Math.Min(gg, bb));
        l = (max + min) / 2.0;
        double d = max - min;
        if (d == 0) { h = 0; s = 0; return; }
        s = (l > 0.5) ? d / (2 - max - min) : d / (max + min);
        if (max == rr) h = 60 * (((gg - bb) / d) % 6);
        else if (max == gg) h = 60 * (((bb - rr) / d) + 2);
        else h = 60 * (((rr - gg) / d) + 4);
        if (h < 0) h += 360;
    }

    static int HueBucket(double h)
    {
        if (h >= 330 || h < 15) return 0;   // red
        if (h < 45) return 1;               // orange
        if (h < 70) return 2;               // yellow
        if (h < 160) return 3;              // green
        if (h < 200) return 4;              // cyan
        if (h < 255) return 5;              // blue
        return 6;                           // purple
    }

    public static IconColorInfo Analyze(string shellPath)
    {
        IconColorInfo res = new IconColorInfo();
        res.ShellPath = shellPath;
        SHFILEINFO info = new SHFILEINFO();
        IntPtr ok = SHGetFileInfo(shellPath, 0, ref info, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), SHGFI_ICON | SHGFI_LARGEICON);
        if (ok == IntPtr.Zero || info.hIcon == IntPtr.Zero) { res.Error = "no icon"; return res; }
        try
        {
            using (Icon ic = Icon.FromHandle(info.hIcon))
            using (Bitmap bmp = ic.ToBitmap())
            {
                int w = bmp.Width, h = bmp.Height;
                double[] hist = new double[36];
                List<int> Rc = new List<int>(), Gc = new List<int>(), Bc = new List<int>();
                long opaque = 0, colored = 0;
                double sumL = 0, sumR = 0, sumG = 0, sumB = 0;
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++)
                    {
                        Color c = bmp.GetPixel(x, y);
                        if (c.A < 40) continue;
                        opaque++;
                        Rc.Add(c.R); Gc.Add(c.G); Bc.Add(c.B);
                        double hue, sat, lit;
                        RgbToHsl(c.R, c.G, c.B, out hue, out sat, out lit);
                        sumL += lit; sumR += c.R; sumG += c.G; sumB += c.B;

                        // v2: vote by area
                        if (sat < 0.18)
                        {
                            if (lit >= 0.85) res.WhiteFrac++;
                            else if (lit <= 0.15) res.BlackFrac++;
                            else res.GrayFrac++;
                        }
                        else
                        {
                            colored++;
                            res.FamFrac[HueBucket(hue)]++;
                            // v1: saturation weighted hue histogram
                            int bin = (int)(hue / 10.0) % 36;
                            double mx = Math.Max(c.R, Math.Max(c.G, c.B)) / 255.0;
                            hist[bin] += sat * (0.35 + 0.65 * mx);
                        }
                    }
                }
                if (opaque == 0) { res.Error = "fully transparent"; return res; }
                res.Found = true;
                res.OpaquePixels = opaque;
                res.Colorfulness = (double)colored / opaque;
                res.Lightness = sumL / opaque;
                res.R = (int)(sumR / opaque); res.G = (int)(sumG / opaque); res.B = (int)(sumB / opaque);

                res.WhiteFrac /= opaque; res.BlackFrac /= opaque; res.GrayFrac /= opaque;
                for (int i = 0; i < 7; i++) res.FamFrac[i] /= opaque;
                int best = 0;
                for (int i = 1; i < 7; i++) if (res.FamFrac[i] > res.FamFrac[best]) best = i;
                res.TopFam = best; res.TopFamFrac = res.FamFrac[best];

                Rc.Sort(); Gc.Sort(); Bc.Sort();
                int m = Rc.Count / 2;
                res.MedR = Rc[m]; res.MedG = Gc[m]; res.MedB = Bc[m];
                double mh, ms, ml;
                RgbToHsl(res.MedR, res.MedG, res.MedB, out mh, out ms, out ml);
                res.MedHue = mh; res.MedSat = ms; res.MedLight = ml;

                if (res.Colorfulness >= 0.08)
                {
                    int peak = 0; double bestv = -1;
                    for (int i = 0; i < 36; i++)
                    {
                        double v = hist[(i + 35) % 36] * 0.5 + hist[i] * 2 + hist[(i + 1) % 36] * 0.5;
                        if (v > bestv) { bestv = v; peak = i; }
                    }
                    double wsum = 0, hsum = 0;
                    double centre = peak * 10 + 5;
                    for (int k = -3; k <= 3; k++)
                    {
                        int i = ((peak + k) % 36 + 36) % 36;
                        double angle = i * 10 + 5;
                        double diff = angle - centre;
                        while (diff > 180) diff -= 360;
                        while (diff < -180) diff += 360;
                        if (Math.Abs(diff) > 35) continue;
                        wsum += hist[i];
                        hsum += hist[i] * (centre + diff);
                    }
                    res.Hue = wsum > 0 ? ((hsum / wsum) % 360 + 360) % 360 : centre;
                }
                return res;
            }
        }
        catch (Exception ex) { res.Error = ex.Message; return res; }
        finally { DestroyIcon(info.hIcon); }
    }
}
