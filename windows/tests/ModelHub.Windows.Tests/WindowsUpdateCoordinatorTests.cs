using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class WindowsUpdateCoordinatorTests
{
    [Theory]
    [InlineData("http://github.com/dw-zhu-si/ModelHub/releases/")]
    [InlineData("https://user:secret@github.com/dw-zhu-si/ModelHub/releases/")]
    [InlineData("https://github.com/dw-zhu-si/ModelHub/releases/?token=secret")]
    [InlineData("https://github.com/dw-zhu-si/ModelHub/releases/#hidden")]
    [InlineData("https://attacker.example/releases/")]
    public void FeedValidationRejectsUnsafeOrUnapprovedUrls(string raw)
    {
        Assert.Throws<InvalidOperationException>(() => VelopackUpdateEngine.ValidateFeedUri(new Uri(raw), ["github.com"]));
    }

    [Fact]
    public void FeedValidationAcceptsCredentialFreeAllowlistedHttps()
    {
        VelopackUpdateEngine.ValidateFeedUri(new Uri("https://github.com/dw-zhu-si/ModelHub/releases/"), ["github.com"]);
    }

    [Fact]
    public async Task UpdateRequiresExplicitStageBeforeApply()
    {
        var engine = new FakeUpdateEngine();
        var coordinator = new WindowsUpdateCoordinator(engine);
        var candidate = await coordinator.CheckAsync();

        Assert.NotNull(candidate);
        Assert.Throws<InvalidOperationException>(coordinator.ApplyStagedAndRestart);

        await coordinator.StageAsync(candidate!);
        coordinator.ApplyStagedAndRestart();

        Assert.Equal(1, engine.DownloadCount);
        Assert.Equal(1, engine.ApplyCount);
    }

    [Fact]
    public async Task CancelledDownloadDoesNotBecomeStaged()
    {
        var engine = new FakeUpdateEngine { CancelDownload = true };
        var coordinator = new WindowsUpdateCoordinator(engine);
        var candidate = await coordinator.CheckAsync();

        await Assert.ThrowsAsync<OperationCanceledException>(() => coordinator.StageAsync(candidate!));
        Assert.Null(coordinator.Staged);
    }

    private sealed class FakeUpdateEngine : IWindowsUpdateEngine
    {
        private readonly WindowsUpdateCandidate _candidate = new("1.10.1", 1_024, new object());
        public bool IsInstalled => true;
        public bool CancelDownload { get; init; }
        public int DownloadCount { get; private set; }
        public int ApplyCount { get; private set; }

        public Task<WindowsUpdateCandidate?> CheckAsync(CancellationToken cancellationToken) => Task.FromResult<WindowsUpdateCandidate?>(_candidate);

        public Task DownloadAsync(WindowsUpdateCandidate candidate, Action<int>? progress, CancellationToken cancellationToken)
        {
            DownloadCount += 1;
            if (CancelDownload)
            {
                throw new OperationCanceledException(cancellationToken);
            }
            progress?.Invoke(100);
            return Task.CompletedTask;
        }

        public void ApplyAndRestart(WindowsUpdateCandidate candidate) => ApplyCount += 1;
    }
}
