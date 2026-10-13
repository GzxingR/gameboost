// GameBoost 基准工具：分配并逐页触碰指定内存，用于验证「冻结 + 回收工作集」到底能腾出多少物理内存。
// 编译：csc /nologo /platform:x64 /out:gbmemballoon.exe MemBalloon.cs
// 用法：gbmemballoon.exe [MB] [秒数]     例如 gbmemballoon.exe 2048 600
// 注意：进程名 gbmemballoon 不在任何保护名单里，可被 pause 脚本冻结；这是刻意命名，避免与 shell 家族冲突。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

internal static class MemBalloon
{
    private static void Main(string[] rawArgs)
    {
        int mb = 2048;
        int seconds = 600;
        if (rawArgs.Length > 0) { int.TryParse(rawArgs[0], out mb); }
        if (rawArgs.Length > 1) { int.TryParse(rawArgs[1], out seconds); }
        if (mb < 1) { mb = 1; }
        if (seconds < 1) { seconds = 1; }

        const int chunkSize = 64 * 1024 * 1024;
        var chunks = new List<byte[]>();
        long made = 0;
        long target = (long)mb * 1024L * 1024L;
        while (made < target)
        {
            int size = (int)Math.Min((long)chunkSize, target - made);
            byte[] c = new byte[size];
            for (int i = 0; i < size; i += 4096) { c[i] = 7; }
            chunks.Add(c);
            made += size;
        }

        Process p = Process.GetCurrentProcess();
        p.Refresh();
        Console.WriteLine("PID=" + p.Id + " WS_MB=" + (p.WorkingSet64 / 1048576L) + " PRIVATE_MB=" + (p.PrivateMemorySize64 / 1048576L) + " CHUNKS=" + chunks.Count);
        Console.Out.Flush();
        Thread.Sleep(seconds * 1000);
    }
}
