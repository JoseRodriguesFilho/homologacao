using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
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
    public DateTimeOffset? TerminationLogoffNotBefore { get; set; }
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
    internal const int MinimumTerminationNoticeSeconds = 15;
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

                foreach (var snapshotSession in snapshot)
                {
                    var session = snapshotSession;

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
                                        session = Clone(current);
                                        SaveStateUnsafe();
                                    }
                                }
                            }

                            // O heartbeat pode cancelar ou atualizar o comando. Usa o
                            // estado novo neste mesmo ciclo para nao atrasar o aviso.
                            if (session.TerminationDeadline is null)
                                continue;
                        }

                        var now = DateTimeOffset.UtcNow;
                        var effectiveDeadline = session.TerminationDeadline.Value;

                        if (session.TerminationLogoffNotBefore is not null &&
                            session.TerminationLogoffNotBefore.Value > effectiveDeadline)
                        {
                            effectiveDeadline =
                                session.TerminationLogoffNotBefore.Value;
                        }

                        if (!session.TerminationNotified)
                        {
                            // Estados gravados por versoes anteriores nao possuem este
                            // campo. Ainda assim garante tempo minimo para leitura.
                            if (session.TerminationLogoffNotBefore is null)
                            {
                                session.TerminationLogoffNotBefore =
                                    now.AddSeconds(MinimumTerminationNoticeSeconds);

                                if (session.TerminationLogoffNotBefore.Value >
                                    effectiveDeadline)
                                {
                                    effectiveDeadline =
                                        session.TerminationLogoffNotBefore.Value;
                                }
                            }

                            var remaining = Math.Max(
                                1,
                                (int)Math.Ceiling(
                                    (effectiveDeadline - now).TotalSeconds));

                            var avisoExibido = WindowsSessionInspector.TrySendMessage(
                                session.WindowsAccount,
                                "e-GOV - Laboratório ao Vivo",
                                BuildTerminationNotice(
                                    session.TerminationMessage),
                                remaining);

                            if (!avisoExibido)
                            {
                                _logger.LogWarning(
                                    "Nao foi possivel exibir o aviso de encerramento " +
                                    "na sessao Windows de {Account}.",
                                    session.WindowsAccount);
                            }
                            else
                            {
                                _logger.LogInformation(
                                    "Aviso de encerramento exibido para {Account}; " +
                                    "logoff em aproximadamente {Seconds} segundos.",
                                    session.WindowsAccount,
                                    remaining);
                            }

                            lock (_sync)
                            {
                                var current = _sessions.FirstOrDefault(
                                    x => x.SessionId.Equals(
                                        session.SessionId,
                                        StringComparison.OrdinalIgnoreCase));
                                if (current is not null)
                                {
                                    // Se a sessao ainda nao estava disponivel,
                                    // tenta exibir novamente no proximo ciclo.
                                    current.TerminationNotified = avisoExibido;
                                    current.TerminationLogoffNotBefore =
                                        session.TerminationLogoffNotBefore;
                                    SaveStateUnsafe();
                                }
                            }
                        }

                        if (DateTimeOffset.UtcNow >= effectiveDeadline)
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
                        }

                        continue;
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
                            {
                                current.TerminationNotified = false;
                                current.TerminationLogoffNotBefore =
                                    DateTimeOffset.UtcNow.AddSeconds(
                                        MinimumTerminationNoticeSeconds);
                            }
                        }
                        else
                        {
                            current.TerminationDeadline = null;
                            current.TerminationLogoffNotBefore = null;
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
        TerminationLogoffNotBefore = s.TerminationLogoffNotBefore,
        TerminationMessage = s.TerminationMessage,
        TerminationNotified = s.TerminationNotified
    };

    private static string BuildTerminationNotice(string message)
    {
        var detail = string.IsNullOrWhiteSpace(message)
            ? "Sua sessão será encerrada pelo administrador."
            : message.Trim();

        return
            "Sua sessão será desconectada em breve.\r\n\r\n" +
            detail +
            "\r\n\r\n" +
            "Salve seu trabalho agora para não perder alterações.";
    }

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
    private const int MbOk = 0x00000000;
    private const int MbIconWarning = 0x00000030;
    private const int MbSetForeground = 0x00010000;
    private const int MbTopMost = 0x00040000;
    private const uint LogonWithProfile = 0x00000001;
    private const uint CreateNewProcessGroup = 0x00000200;
    private const uint CreateUnicodeEnvironment = 0x00000400;

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

        var popupDuration = Math.Max(5, secondsRemaining);

        if (TryStartCustomNotice(sessionId, message, popupDuration))
            return true;

        // Contingencia para computadores onde a criacao do processo grafico
        // na sessao do usuario seja bloqueada por alguma politica do Windows.
        var timeout = Math.Min(popupDuration, 300);
        var nativeMessage =
            message +
            "\r\n\r\n" + FormatNoticeDuration(popupDuration);

        return WTSSendMessageW(
            WtsCurrentServerHandle,
            sessionId,
            title,
            title.Length * sizeof(char),
            nativeMessage,
            nativeMessage.Length * sizeof(char),
            MbOk | MbIconWarning | MbSetForeground | MbTopMost,
            timeout,
            out _,
            false);
    }

    internal static string FormatNoticeDuration(int seconds)
    {
        if (seconds <= AgentWorker.MinimumTerminationNoticeSeconds)
            return "Tempo para encerramento: menos de 1 minuto.";

        var minutes = (int)Math.Ceiling(seconds / 60d);
        return minutes == 1
            ? "Tempo para encerramento: 1 minuto."
            : $"Tempo para encerramento: {minutes} minutos.";
    }

    private static bool TryStartCustomNotice(
        int sessionId,
        string message,
        int timeoutSeconds)
    {
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable))
            return false;

        if (!WTSQueryUserToken((uint)sessionId, out var userToken))
            return false;

        IntPtr environment = IntPtr.Zero;

        try
        {
            var environmentCreated =
                CreateEnvironmentBlock(out environment, userToken, false);
            var creationFlags = CreateNewProcessGroup;

            if (environmentCreated)
                creationFlags |= CreateUnicodeEnvironment;

            var encodedMessage = Convert.ToBase64String(
                Encoding.UTF8.GetBytes(message));
            var commandText =
                $"\"{executable}\" --termination-notice {encodedMessage} " +
                timeoutSeconds;
            var commandLine = new StringBuilder(commandText);
            var startupInfo = new STARTUPINFO
            {
                cb = Marshal.SizeOf<STARTUPINFO>(),
                lpDesktop = @"winsta0\default"
            };

            var started = CreateProcessAsUserW(
                    userToken,
                    executable,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    creationFlags,
                    environmentCreated ? environment : IntPtr.Zero,
                    Path.GetDirectoryName(executable),
                    ref startupInfo,
                    out var processInfo);

            if (!started)
            {
                commandLine = new StringBuilder(commandText);
                started = CreateProcessWithTokenW(
                    userToken,
                    LogonWithProfile,
                    executable,
                    commandLine,
                    creationFlags,
                    environmentCreated ? environment : IntPtr.Zero,
                    Path.GetDirectoryName(executable),
                    ref startupInfo,
                    out processInfo);
            }

            if (!started)
                return false;

            CloseHandle(processInfo.hThread);
            CloseHandle(processInfo.hProcess);
            return true;
        }
        finally
        {
            if (environment != IntPtr.Zero)
                DestroyEnvironmentBlock(environment);

            CloseHandle(userToken);
        }
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
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

    [DllImport("Wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(
        uint sessionId,
        out IntPtr token);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool CreateEnvironmentBlock(
        out IntPtr environment,
        IntPtr token,
        bool inherit);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool DestroyEnvironmentBlock(IntPtr environment);

    [DllImport(
        "advapi32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern bool CreateProcessAsUserW(
        IntPtr token,
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string? currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport(
        "advapi32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern bool CreateProcessWithTokenW(
        IntPtr token,
        uint logonFlags,
        string applicationName,
        StringBuilder commandLine,
        uint creationFlags,
        IntPtr environment,
        string? currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}

public static class TerminationNoticeWindow
{
    private const string NoticeArgument = "--termination-notice";

    public static bool RunIfRequested(string[] args)
    {
        if (args.Length == 0 ||
            !args[0].Equals(NoticeArgument, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var message = DecodeMessage(args.ElementAtOrDefault(1));
        var seconds = int.TryParse(args.ElementAtOrDefault(2), out var parsed)
            ? Math.Max(1, parsed)
            : 15;

        var uiThread = new Thread(() => Show(message, seconds))
        {
            IsBackground = false,
            Name = "e-GOV termination notice"
        };
        uiThread.SetApartmentState(ApartmentState.STA);
        uiThread.Start();
        uiThread.Join();
        return true;
    }

    private static string DecodeMessage(string? encoded)
    {
        if (string.IsNullOrWhiteSpace(encoded))
            return "Sua sessão será encerrada pelo administrador.";

        try
        {
            return Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
        }
        catch (FormatException)
        {
            return "Sua sessão será encerrada pelo administrador.";
        }
    }

    private static void Show(string message, int seconds)
    {
        var blue = new SolidColorBrush(Color.FromRgb(0x00, 0x66, 0xCC));
        var white = Brushes.White;
        var window = new Window
        {
            Title = "e-GOV - Laboratório ao Vivo",
            Background = blue,
            Foreground = white,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStyle = WindowStyle.None,
            Padding = new Thickness(20),
            Topmost = true,
            ShowActivated = true,
            ShowInTaskbar = true
        };

        var panel = new Grid
        {
            MinWidth = 760,
            MaxWidth = 1040,
            Background = blue
        };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var messageBlock = new TextBlock
        {
            Text = message,
            FontSize = 36,
            Foreground = white,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 880,
            Margin = new Thickness(100, 60, 100, 30)
        };
        Grid.SetRow(messageBlock, 0);

        var duration = new TextBlock
        {
            Text = WindowsSessionInspector.FormatNoticeDuration(seconds),
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = white,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(100, 0, 100, 30)
        };
        Grid.SetRow(duration, 1);

        var okButton = new Button
        {
            Content = "OK",
            Width = 75,
            Padding = new Thickness(12, 6, 12, 6),
            Background = blue,
            BorderBrush = white,
            BorderThickness = new Thickness(1),
            Foreground = white,
            FontSize = 16,
            IsDefault = true,
            IsCancel = true,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 30, 20)
        };
        okButton.Click += (_, _) => window.Close();
        Grid.SetRow(okButton, 2);

        panel.Children.Add(messageBlock);
        panel.Children.Add(duration);
        panel.Children.Add(okButton);
        window.Content = panel;

        var timer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(seconds)
        };

        timer.Tick += (_, _) =>
        {
            timer.Stop();
            window.Close();
        };
        window.Loaded += (_, _) =>
        {
            timer.Start();
            window.Activate();
            okButton.Focus();
        };
        window.Closed += (_, _) => timer.Stop();
        window.ShowDialog();
    }
}

public static class Program
{
    public static async Task Main(string[] args)
    {
        if (TerminationNoticeWindow.RunIfRequested(args))
            return;

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
