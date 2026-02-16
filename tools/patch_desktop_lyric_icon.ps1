$root = Split-Path -Parent $PSScriptRoot
$icoPath = Join-Path $root "app_icon.ico"
$exePaths = @(
  (Join-Path $root "desktop_lyric\\desktop_lyric.exe"),
  (Join-Path $root "output\\desktop_lyric\\desktop_lyric.exe")
) | Where-Object { Test-Path $_ }

if (-not (Test-Path $icoPath)) {
  throw "app_icon.ico not found: $icoPath"
}
if ($exePaths.Count -eq 0) {
  throw "desktop_lyric.exe not found"
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class ExeIconPatcher
{
    private const int RT_ICON = 3;
    private const int RT_GROUP_ICON = 14;

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct ICONDIR { public UInt16 Reserved; public UInt16 Type; public UInt16 Count; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct ICONDIRENTRY
    {
        public byte Width;
        public byte Height;
        public byte ColorCount;
        public byte Reserved;
        public UInt16 Planes;
        public UInt16 BitCount;
        public UInt32 BytesInRes;
        public UInt32 ImageOffset;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BeginUpdateResource(string pFileName, [MarshalAs(UnmanagedType.Bool)] bool bDeleteExistingResources);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, UInt16 wLanguage, byte[] lpData, UInt32 cbData);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr hUpdate, [MarshalAs(UnmanagedType.Bool)] bool fDiscard);

    private static IntPtr MakeIntResource(int id)
    {
        return (IntPtr)id;
    }

    public static void SetIcon(string exePath, string icoPath)
    {
        var icoBytes = File.ReadAllBytes(icoPath);
        ICONDIR dir;
        ICONDIRENTRY[] entries;
        byte[][] images;

        using (var ms = new MemoryStream(icoBytes))
        using (var br = new BinaryReader(ms))
        {
            dir = new ICONDIR { Reserved = br.ReadUInt16(), Type = br.ReadUInt16(), Count = br.ReadUInt16() };
            if (dir.Reserved != 0 || dir.Type != 1 || dir.Count == 0) throw new InvalidDataException("Invalid ico header");
            entries = new ICONDIRENTRY[dir.Count];
            images = new byte[dir.Count][];
            for (int i = 0; i < dir.Count; i++)
            {
                entries[i] = new ICONDIRENTRY
                {
                    Width = br.ReadByte(),
                    Height = br.ReadByte(),
                    ColorCount = br.ReadByte(),
                    Reserved = br.ReadByte(),
                    Planes = br.ReadUInt16(),
                    BitCount = br.ReadUInt16(),
                    BytesInRes = br.ReadUInt32(),
                    ImageOffset = br.ReadUInt32(),
                };
            }
            for (int i = 0; i < dir.Count; i++)
            {
                var e = entries[i];
                if (e.ImageOffset + e.BytesInRes > icoBytes.Length) throw new InvalidDataException("Invalid ico image offset");
                images[i] = new byte[e.BytesInRes];
                Buffer.BlockCopy(icoBytes, (int)e.ImageOffset, images[i], 0, (int)e.BytesInRes);
            }
        }

        var hUpdate = BeginUpdateResource(exePath, false);
        if (hUpdate == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());

        try
        {
            for (int i = 0; i < images.Length; i++)
            {
                if (!UpdateResource(hUpdate, MakeIntResource(RT_ICON), MakeIntResource(i + 1), 0, images[i], (UInt32)images[i].Length))
                    throw new Exception("UpdateResource RT_ICON failed: " + Marshal.GetLastWin32Error());
            }

            using (var ms = new MemoryStream())
            using (var bw = new BinaryWriter(ms))
            {
                bw.Write((UInt16)0);
                bw.Write((UInt16)1);
                bw.Write((UInt16)entries.Length);
                for (int i = 0; i < entries.Length; i++)
                {
                    var e = entries[i];
                    bw.Write(e.Width);
                    bw.Write(e.Height);
                    bw.Write(e.ColorCount);
                    bw.Write(e.Reserved);
                    bw.Write(e.Planes);
                    bw.Write(e.BitCount);
                    bw.Write(e.BytesInRes);
                    bw.Write((UInt16)(i + 1));
                }
                bw.Flush();
                var grp = ms.ToArray();
                if (!UpdateResource(hUpdate, MakeIntResource(RT_GROUP_ICON), MakeIntResource(1), 0, grp, (UInt32)grp.Length))
                    throw new Exception("UpdateResource RT_GROUP_ICON failed: " + Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            if (!EndUpdateResource(hUpdate, false))
                throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
        }
    }
}
'@ -Language CSharp -ErrorAction Stop

foreach ($exe in $exePaths) {
  [ExeIconPatcher]::SetIcon($exe, $icoPath)
}
