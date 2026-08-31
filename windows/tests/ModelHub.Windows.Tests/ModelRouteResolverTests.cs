using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class ModelRouteResolverTests
{
    [Fact]
    public void DirectModelWinsWithoutAliasResolution()
    {
        var configuration = Configuration();
        var resolution = new ModelRouteResolver().Resolve(configuration, [], "m1");

        Assert.NotNull(resolution);
        Assert.False(resolution.UsedAlias);
        Assert.Equal("p1", resolution.Provider.DisplayName);
    }

    [Fact]
    public void PriorityFailoverSkipsConfigurationAndUnavailableTargets()
    {
        var configuration = Configuration();
        var route = Route(configuration, ModelRouteStrategy.PriorityFailover);
        var first = configuration.Providers[0];
        var resolution = new ModelRouteResolver().Resolve(configuration, [route], "smart", (provider, _) =>
            provider == first.Id ? RouteTargetState.ConfigurationRequired : RouteTargetState.Available);

        Assert.NotNull(resolution);
        Assert.Equal("p2", resolution.Provider.DisplayName);
        Assert.True(resolution.UsedAlias);
    }

    [Fact]
    public void AvailableTargetPrecedesLowerPriorityDegradedTarget()
    {
        var configuration = Configuration();
        var route = Route(configuration, ModelRouteStrategy.PriorityFailover) with
        {
            Targets =
            [
                new ModelRouteTarget(configuration.Providers[0].Id, "m1", Priority: 0),
                new ModelRouteTarget(configuration.Providers[1].Id, "m2", Priority: 9),
            ],
        };
        var resolution = new ModelRouteResolver().Resolve(configuration, [route], "smart", (provider, _) =>
            provider == configuration.Providers[0].Id ? RouteTargetState.Degraded : RouteTargetState.Available);

        Assert.Equal("p2", resolution?.Provider.DisplayName);
    }

    [Fact]
    public void RoundRobinIsDeterministicAndBounded()
    {
        var configuration = Configuration();
        var route = Route(configuration, ModelRouteStrategy.RoundRobin);
        var resolver = new ModelRouteResolver();

        var selected = Enumerable.Range(0, 4)
            .Select(_ => resolver.Resolve(configuration, [route], "smart")!.Provider.DisplayName)
            .ToArray();

        Assert.Equal("p1", selected[0]);
        Assert.Equal("p2", selected[1]);
        Assert.Equal("p1", selected[2]);
        Assert.Equal("p2", selected[3]);
    }

    [Fact]
    public void WeightedSelectionUsesOnlyCurrentlyAvailableTargets()
    {
        var configuration = Configuration();
        var route = Route(configuration, ModelRouteStrategy.WeightedRandom);
        var resolver = new ModelRouteResolver(_ => 0);
        var resolution = resolver.Resolve(configuration, [route], "smart", (provider, _) =>
            provider == configuration.Providers[0].Id ? RouteTargetState.Degraded : RouteTargetState.Available);

        Assert.Equal("p2", resolution?.Provider.DisplayName);
    }

    [Fact]
    public void InvalidAliasOrMissingTargetFailsClosed()
    {
        var configuration = Configuration();
        var invalid = new ModelRouteDefinition("smart", true, ModelRouteStrategy.PriorityFailover,
        [
            new ModelRouteTarget(Guid.NewGuid(), "missing"),
        ]);

        Assert.Null(new ModelRouteResolver().Resolve(configuration, [invalid], "smart"));
        Assert.Null(new ModelRouteResolver().Resolve(configuration, [Route(configuration, ModelRouteStrategy.PriorityFailover)], "unknown"));
    }

    private static ModelHubConfiguration Configuration()
    {
        var first = new ProviderConfiguration(Guid.NewGuid(), "p1", new Uri("https://p1.example/"), true, [new ModelDefinition("m1", "m1", "text")]);
        var second = new ProviderConfiguration(Guid.NewGuid(), "p2", new Uri("https://p2.example/"), true, [new ModelDefinition("m2", "m2", "text")]);
        return ModelHubConfiguration.Empty with { Providers = [first, second] };
    }

    private static ModelRouteDefinition Route(ModelHubConfiguration configuration, ModelRouteStrategy strategy)
    {
        return new ModelRouteDefinition("smart", true, strategy,
        [
            new ModelRouteTarget(configuration.Providers[0].Id, "m1", Priority: 0, Weight: 1),
            new ModelRouteTarget(configuration.Providers[1].Id, "m2", Priority: 1, Weight: 3),
        ]);
    }

}
