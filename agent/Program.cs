using System.Net;
using System.IO.Pipes;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Win32;

namespace EGOVLabCPFAgent;

public sealed class AgentConfig
{
    public required string ApiBaseUrl { get; init; }
    public required string ApiToken { get; init; }

    public static AgentConfig? Read()
    {
        using var key = Registry.LocalMachine.OpenSubKey(
            @"SOFTWARE\e-GOV\LabCPFProvider",
            writable: false);

        var baseUrl = key?.GetValue("ApiBaseUrl") as string;
        var token = key?.GetValue("ApiToken") as string;

        if (string.IsNullOrWhiteSpace(baseUrl) ||
            string.IsNullOrWhiteSpace(token))
        {
            return null;
        }

        return new AgentConfig
        {
            ApiBaseUrl = baseUrl.TrimEnd('/'),
            ApiToken = token
        };
    }
}

public sealed class AuthMessage
{
    public string SessionId { get; set; } = "";
    public string WindowsAccount { get; set; } = "";
    public string Role { get; set; } = "";
    public string Action { get; set; } = "";
}

public sealed class SessionContext
{
    public string SessionId { get; set; } = "";
    public string WindowsAccount { get; set; } = "";
    public string Role { get; set; } = "";
    public string Action { get; set; } = "";
    public DateTimeOffset AddedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastHeartbeat { get; set; } = DateTimeOffset.MinValue;
    public DateTimeOffset? TerminationDeadline { get; set; }
    public string TerminationMessage { get; set; } = "";
    public bool TerminationNotified { get; set; }
}

public sealed class HeartbeatResponse
{
    public bool Ok { get; set; }
    public string? Command { get; set; }
    public DateTimeOffset? TerminationDeadline { get; set; }
    public string? TerminationMessage { get; set; }
    public int? SecondsRemaining { get; set; }
}

public sealed class AgentWorker : BackgroundService
{
    private const string PipeName = "eGOVLabCPFAgent";
    private readonly ILogger<AgentWorker> _logger;
    private readonly HttpClient _http;
    private readonly object _sync = new();
    private readonly List<SessionContext> _sessions = new();

    private static readonly string StateDirectory =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "e-GOV",
            "LabCPF");

    private static readonly string StatePath =
        Path.Combine(StateDirectory, "agent-state.json");

    public AgentWorker(ILogger<AgentWorker> logger)
    {
        _logger = logger;
        _http = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(5)
        };

        Directory.CreateDirectory(StateDirectory);
        LoadState();
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("e-GOV Lab CPF Agent iniciado.");

        var pipeTask = RunPipeLoopAsync(stoppingToken);
        var monitorTask = RunMonitorLoopAsync(stoppingToken);

        await Task.WhenAll(pipeTask, monitorTask);
    }

    private async Task RunPipeLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(
                    PipeName,
                    PipeDirection.In,
                    8,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                await pipe.WaitForConnectionAsync(token);

                using var reader = new StreamReader(pipe);
                var payload = await reader.ReadToEndAsync(token);

                if (string.IsNullOrWhiteSpace(payload))
                    continue;

                var message = JsonSerializer.Deserialize<AuthMessage>(
                    payload,
                    JsonOptions());

                if (message is null ||
                    string.IsNullOrWhiteSpace(message.SessionId) ||
                    string.IsNullOrWhiteSpace(message.WindowsAccount))
                {
                    _logger.LogWarning("Mensagem invalida recebida pelo pipe.");
                    continue;
                }

                lock (_sync)
                {
                    var existing = _sessions.FirstOrDefault(
                        s => s.SessionId.Equals(
                            message.SessionId,
                            StringComparison.OrdinalIgnoreCase));

                    if (existing is null)
                    {
                        _sessions.Add(new SessionContext
                        {
                            SessionId = message.SessionId,
                            WindowsAccount = message.WindowsAccount,
                            Role = message.Role,
                            Action = message.Action,
                            AddedAt = DateTimeOffset.UtcNow
                        });
                    }
                    else
                    {
                        existing.WindowsAccount = message.WindowsAccount;
                        existing.Role = message.Role;
                        existing.Action = message.Action;
                    }

                    SaveStateUnsafe();
                }

                _logger.LogInformation(
                    "Sessao recebida: {SessionId} / {Account} / {Role}",
                    message.SessionId,
                    message.WindowsAccount,
                    message.Role);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Erro no Named Pipe.");
                await Task.Delay(TimeSpan.FromSeconds(2), token);
            }
        }
    }

    private async Task RunMonitorLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                List<SessionContext> snapshot;

                lock (_sync)
                {
                    snapshot = _sessions
                        .Select(Clone)
                        .ToList();
                }

                foreach (var session in snapshot)
                {
                    if (session.TerminationDeadline is not null)
                    {
                        if (DateTimeOffset.UtcNow < session.TerminationDeadline.Value &&
                            DateTimeOffset.UtcNow - session.LastHeartbeat >=
                            TimeSpan.FromSeconds(5))
                        {
                            var refreshed = await SendHeartbeatAsync(session, token);
                            if (refreshed)
                            {
                                lock (_sync)
                                {
                                    var current = _sessions.FirstOrDefault(
                                        x => x.SessionId.Equals(
                                            session.SessionId,
                                            StringComparison.OrdinalIgnoreCase));
                                    if (current is not null)
                                    {
                                        current.LastHeartbeat = DateTimeOffset.UtcNow;
                                        SaveStateUnsafe();
                                    }
                                }
                            }

                            // Usa o estado atualizado no proximo ciclo, inclusive
                            // quando o administrador cancelou o encerramento.
                            continue;
                        }

                        if (!session.TerminationNotified)
                        {
                            var remaining = Math.Max(
                                0,
                                (int)Math.Ceiling(
                                    (session.TerminationDeadline.Value -
                                     DateTimeOffset.UtcNow).TotalSeconds));

                            WindowsSessionInspector.TrySendMessage(
                                session.WindowsAccount,
                                "e-GOV - Encerramento de sessao",
                                session.TerminationMessage +
                                $"\n\nEncerramento em {remaining} segundos.",
                                remaining);

                            lock (_sync)
                            {
                                var current = _sessions.FirstOrDefault(
                                    x => x.SessionId.Equals(
                                        session.SessionId,
                                        StringComparison.OrdinalIgnoreCase));
                                if (current is not null)
                                {
                                    current.TerminationNotified = true;
                                    SaveStateUnsafe();
                                }
                            }
                        }

                        if (DateTimeOffset.UtcNow >= session.TerminationDeadline.Value)
                        {
                            if (WindowsSessionInspector.TryLogoff(
                                    session.WindowsAccount))
                            {
                                await SendLogoutAsync(
                                    session,
                                    "remote_termination",
                                    token);
                                RemoveSession(session.SessionId);
                            }
                            continue;
                        }
                    }

                    if (!WindowsSessionInspector.IsUserLoggedOn(session.WindowsAccount))
                    {
                        // O Credential Provider avisa o Agent imediatamente antes de o
                        // Windows concluir o logon/unlock. Evita encerrar a sessao da API
                        // durante essa pequena janela.
                        if (DateTimeOffset.UtcNow - session.AddedAt <
                            TimeSpan.FromSeconds(20))
                        {
                            continue;
                        }

                        await SendLogoutAsync(session, "windows_logoff", token);
                        RemoveSession(session.SessionId);
                        continue;
                    }

                    if (DateTimeOffset.UtcNow - session.LastHeartbeat >=
                        TimeSpan.FromSeconds(30))
                    {
                        var ok = await SendHeartbeatAsync(session, token);

                        if (ok)
                        {
                            lock (_sync)
                            {
                                var current = _sessions.FirstOrDefault(
                                    x => x.SessionId.Equals(
                                        session.SessionId,
                                        StringComparison.OrdinalIgnoreCase));

                                if (current is not null)
                                {
                                    current.LastHeartbeat = DateTimeOffset.UtcNow;
                                    SaveStateUnsafe();
                                }
                            }
                        }
                    }
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Erro no ciclo do Agent.");
            }

            await Task.Delay(TimeSpan.FromSeconds(5), token);
        }
    }

    private async Task<bool> SendHeartbeatAsync(
        SessionContext session,
        CancellationToken token)
    {
        var config = AgentConfig.Read();

        if (config is null)
        {
            _logger.LogWarning("API ainda nao configurada.");
            return false;
        }

        var network = NetworkIdentity.GetPrimary();

        var body = new
        {
            session_id = session.SessionId,
            computer = Environment.MachineName,
            ip = network.Ip,
            mac = network.Mac
        };

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{config.ApiBaseUrl}/sessions/heartbeat")
        {
            Content = JsonContent.Create(body)
        };

        request.Headers.TryAddWithoutValidation(
            "X-eGOV-Token",
            config.ApiToken);

        try
        {
            using var response = await _http.SendAsync(request, token);

            if (response.IsSuccessStatusCode)
            {
                var heartbeat = await response.Content.ReadFromJsonAsync<HeartbeatResponse>(
                    JsonOptions(),
                    token);

                lock (_sync)
                {
                    var current = _sessions.FirstOrDefault(
                        x => x.SessionId.Equals(
                            session.SessionId,
                            StringComparison.OrdinalIgnoreCase));

                    if (current is not null)
                    {
                        var terminate = heartbeat?.Command?.Equals(
                            "terminate",
                            StringComparison.OrdinalIgnoreCase) == true;

                        if (terminate)
                        {
                            var changed =
                                current.TerminationDeadline != heartbeat!.TerminationDeadline ||
                                !string.Equals(
                                    current.TerminationMessage,
                                    heartbeat.TerminationMessage ?? "",
                                    StringComparison.Ordinal);

                            current.TerminationDeadline = heartbeat.TerminationDeadline;
                            current.TerminationMessage =
                                heartbeat.TerminationMessage ??
                                "Sua sessao sera encerrada pelo administrador.";

                            if (changed)
                                current.TerminationNotified = false;
                        }
                        else
                        {
                            current.TerminationDeadline = null;
                            current.TerminationMessage = "";
                            current.TerminationNotified = false;
                        }

                        SaveStateUnsafe();
                    }
                }

                return true;
            }

            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Conflict)
            {
                _logger.LogWarning(
                    "Sessao {SessionId} nao esta mais ativa na API. Removendo contexto local.",
                    session.SessionId);

                RemoveSession(session.SessionId);
            }

            return false;
        }
        catch (HttpRequestException ex)
        {
            _logger.LogWarning(
                ex,
                "API indisponivel durante heartbeat de {SessionId}.",
                session.SessionId);

            return false;
        }
    }

    private async Task SendLogoutAsync(
        SessionContext session,
        string reason,
        CancellationToken token)
    {
        var config = AgentConfig.Read();

        if (config is null)
            return;

        var body = new
        {
            session_id = session.SessionId,
            computer = Environment.MachineName,
            reason
        };

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{config.ApiBaseUrl}/sessions/logout")
        {
            Content = JsonContent.Create(body)
        };

        request.Headers.TryAddWithoutValidation(
            "X-eGOV-Token",
            config.ApiToken);

        try
        {
            using var response = await _http.SendAsync(request, token);
            _logger.LogInformation(
                "Logout enviado para {SessionId}: HTTP {Status}",
                session.SessionId,
                (int)response.StatusCode);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Nao foi possivel enviar logout da sessao {SessionId}.",
                session.SessionId);
        }
    }

    private void RemoveSession(string sessionId)
    {
        lock (_sync)
        {
            _sessions.RemoveAll(
                x => x.SessionId.Equals(
                    sessionId,
                    StringComparison.OrdinalIgnoreCase));

            SaveStateUnsafe();
        }
    }

    private static SessionContext Clone(SessionContext s) => new()
    {
        SessionId = s.SessionId,
        WindowsAccount = s.WindowsAccount,
        Role = s.Role,
        Action = s.Action,
        AddedAt = s.AddedAt,
        LastHeartbeat = s.LastHeartbeat,
        TerminationDeadline = s.TerminationDeadline,
        TerminationMessage = s.TerminationMessage,
        TerminationNotified = s.TerminationNotified
    };

    private void LoadState()
    {
        try
        {
            if (!File.Exists(StatePath))
                return;

            var json = File.ReadAllText(StatePath);
            var list = JsonSerializer.Deserialize<List<SessionContext>>(
                json,
                JsonOptions());

            if (list is not null)
            {
                _sessions.Clear();
                _sessions.AddRange(list);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Nao foi possivel carregar o estado anterior.");
        }
    }

    private void SaveStateUnsafe()
    {
        try
        {
            var json = JsonSerializer.Serialize(
                _sessions,
                JsonOptions(indented: true));

            File.WriteAllText(StatePath, json);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Nao foi possivel salvar o estado.");
        }
    }

    private static JsonSerializerOptions JsonOptions(bool indented = false) => new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = indented
    };
}

public static class NetworkIdentity
{
    public sealed record Result(string? Ip, string? Mac);

    public static Result GetPrimary()
    {
        var candidates = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n =>
                n.OperationalStatus == OperationalStatus.Up &&
                n.NetworkInterfaceType is
                    NetworkInterfaceType.Ethernet or
                    NetworkInterfaceType.GigabitEthernet or
                    NetworkInterfaceType.Wireless80211)
            .Select(n => new
            {
                Nic = n,
                Props = SafeProperties(n)
            })
            .Where(x => x.Props is not null)
            .Select(x => new
            {
                x.Nic,
                Props = x.Props!,
                HasGateway = x.Props!.GatewayAddresses.Any(
                    g => g.Address.AddressFamily == AddressFamily.InterNetwork &&
                         !g.Address.Equals(IPAddress.Any) &&
                         !g.Address.Equals(IPAddress.None))
            })
            .OrderByDescending(x => x.HasGateway)
            .ToList();

        foreach (var candidate in candidates)
        {
            var ip = candidate.Props.UnicastAddresses
                .Select(u => u.Address)
                .FirstOrDefault(IsUsableIpv4);

            if (ip is null)
                continue;

            var macBytes = candidate.Nic.GetPhysicalAddress().GetAddressBytes();
            var mac = macBytes.Length > 0
                ? string.Join("-", macBytes.Select(b => b.ToString("X2")))
                : null;

            return new Result(ip.ToString(), mac);
        }

        return new Result(null, null);
    }

    private static IPInterfaceProperties? SafeProperties(NetworkInterface nic)
    {
        try
        {
            return nic.GetIPProperties();
        }
        catch
        {
            return null;
        }
    }

    private static bool IsUsableIpv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork)
            return false;

        var text = address.ToString();

        return !IPAddress.IsLoopback(address) &&
               !text.StartsWith("169.254.", StringComparison.Ordinal);
    }
}

public static class WindowsSessionInspector
{
    private static readonly IntPtr WtsCurrentServerHandle = IntPtr.Zero;

    public static bool IsUserLoggedOn(string expectedUser)
    {
        IntPtr sessionInfo = IntPtr.Zero;

        try
        {
            if (!WTSEnumerateSessionsW(
                    WtsCurrentServerHandle,
                    0,
                    1,
                    out sessionInfo,
                    out var count))
            {
                return false;
            }

            var dataSize = Marshal.SizeOf<WTS_SESSION_INFO>();
            var current = sessionInfo;

            for (var i = 0; i < count; i++)
            {
                var info = Marshal.PtrToStructure<WTS_SESSION_INFO>(current);

                if (TryGetSessionUser(info.SessionID, out var user) &&
                    user.Equals(expectedUser, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }

                current = IntPtr.Add(current, dataSize);
            }

            return false;
        }
        finally
        {
            if (sessionInfo != IntPtr.Zero)
                WTSFreeMemory(sessionInfo);
        }
    }

    public static bool TrySendMessage(
        string expectedUser,
        string title,
        string message,
        int secondsRemaining)
    {
        if (!TryFindSessionId(expectedUser, out var sessionId))
            return false;

        var timeout = Math.Max(5, Math.Min(secondsRemaining, 300));
        return WTSSendMessageW(
            WtsCurrentServerHandle,
            sessionId,
            title,
            title.Length * sizeof(char),
            message,
            message.Length * sizeof(char),
            0x00000000 | 0x00000030,
            timeout,
            out _,
            false);
    }

    public static bool TryLogoff(string expectedUser)
    {
        return TryFindSessionId(expectedUser, out var sessionId) &&
               WTSLogoffSession(
                   WtsCurrentServerHandle,
                   sessionId,
                   false);
    }

    private static bool TryFindSessionId(string expectedUser, out int sessionId)
    {
        sessionId = -1;
        IntPtr sessionInfo = IntPtr.Zero;

        try
        {
            if (!WTSEnumerateSessionsW(
                    WtsCurrentServerHandle,
                    0,
                    1,
                    out sessionInfo,
                    out var count))
            {
                return false;
            }

            var dataSize = Marshal.SizeOf<WTS_SESSION_INFO>();
            var current = sessionInfo;

            for (var i = 0; i < count; i++)
            {
                var info = Marshal.PtrToStructure<WTS_SESSION_INFO>(current);

                if (TryGetSessionUser(info.SessionID, out var user) &&
                    user.Equals(expectedUser, StringComparison.OrdinalIgnoreCase))
                {
                    sessionId = info.SessionID;
                    return true;
                }

                current = IntPtr.Add(current, dataSize);
            }

            return false;
        }
        finally
        {
            if (sessionInfo != IntPtr.Zero)
                WTSFreeMemory(sessionInfo);
        }
    }

    private static bool TryGetSessionUser(int sessionId, out string user)
    {
        user = "";
        IntPtr buffer = IntPtr.Zero;

        try
        {
            if (!WTSQuerySessionInformationW(
                    WtsCurrentServerHandle,
                    sessionId,
                    WTS_INFO_CLASS.WTSUserName,
                    out buffer,
                    out var bytes) ||
                buffer == IntPtr.Zero ||
                bytes <= 2)
            {
                return false;
            }

            user = Marshal.PtrToStringUni(buffer) ?? "";
            return !string.IsNullOrWhiteSpace(user);
        }
        finally
        {
            if (buffer != IntPtr.Zero)
                WTSFreeMemory(buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WTS_SESSION_INFO
    {
        public int SessionID;
        public IntPtr pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    private enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive,
        WTSConnected,
        WTSConnectQuery,
        WTSShadow,
        WTSDisconnected,
        WTSIdle,
        WTSListen,
        WTSReset,
        WTSDown,
        WTSInit
    }

    private enum WTS_INFO_CLASS
    {
        WTSInitialProgram,
        WTSApplicationName,
        WTSWorkingDirectory,
        WTSOEMId,
        WTSSessionId,
        WTSUserName,
        WTSWinStationName
    }

    [DllImport("Wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSEnumerateSessionsW(
        IntPtr hServer,
        int reserved,
        int version,
        out IntPtr ppSessionInfo,
        out int pCount);

    [DllImport("Wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(
        IntPtr hServer,
        int sessionId,
        WTS_INFO_CLASS wtsInfoClass,
        out IntPtr ppBuffer,
        out int pBytesReturned);

    [DllImport("Wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    [DllImport("Wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WTSSendMessageW(
        IntPtr server,
        int sessionId,
        string title,
        int titleLength,
        string message,
        int messageLength,
        int style,
        int timeout,
        out int response,
        bool wait);

    [DllImport("Wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSLogoffSession(
        IntPtr server,
        int sessionId,
        bool wait);
}

public static class Program
{
    public static async Task Main(string[] args)
    {
        var builder = Host.CreateApplicationBuilder(args);

        builder.Services.AddWindowsService(options =>
        {
            options.ServiceName = "e-GOV Lab CPF Agent";
        });

        builder.Services.AddHostedService<AgentWorker>();

        var host = builder.Build();
        await host.RunAsync();
    }
}
