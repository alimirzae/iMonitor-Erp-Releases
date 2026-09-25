public sealed class AutoUpdateWorker : BackgroundService
{
    private readonly IServiceProvider _services;
    private readonly ILogger<AutoUpdateWorker> _logger;

    public AutoUpdateWorker(IServiceProvider services, ILogger<AutoUpdateWorker> logger)
    {
        _services = services;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = _services.CreateScope();
                var orchestrator = scope.ServiceProvider.GetRequiredService<OrchestratorService>();
                await orchestrator.RunAutoUpdateCycleAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Auto-update cycle failed.");
            }

            try { await Task.Delay(TimeSpan.FromMinutes(5), stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        }
    }
}
