using System.Text.Json;
using System.Text.Json.Serialization;
using WinForge.Core.Models;

namespace WinForge.Core.Services;

public sealed class JsonFileHelper
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static readonly JsonSerializerOptions ReadOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public static async Task WriteAsync<T>(string path, T value, CancellationToken ct = default)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        var temp = path + ".tmp";
        var json = JsonSerializer.Serialize(value, WriteOptions);
        await File.WriteAllTextAsync(temp, json, ct);

        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                File.Copy(temp, path, overwrite: true);
                break;
            }
            catch (IOException) when (attempt < 9)
            {
                await Task.Delay(30 + attempt * 30, ct);
            }
        }

        try { File.Delete(temp); } catch { /* ignore */ }
    }

    public static async Task<T?> ReadAsync<T>(string path, CancellationToken ct = default)
    {
        if (!File.Exists(path))
            return default;

        for (var attempt = 0; attempt < 6; attempt++)
        {
            try
            {
                await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var reader = new StreamReader(stream);
                var json = await reader.ReadToEndAsync(ct);
                if (string.IsNullOrWhiteSpace(json))
                    return default;
                return JsonSerializer.Deserialize<T>(json, ReadOptions);
            }
            catch (IOException) when (attempt < 5)
            {
                await Task.Delay(25 + attempt * 25, ct);
            }
        }

        return default;
    }
}
