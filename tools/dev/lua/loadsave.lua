local gi = FindFirstOf("MLGameInstance")
gi.savefileToLoad = "coop_test_1"
StaticFindObject("/Script/Engine.Default__GameplayStatics"):OpenLevel(gi, FName("Mission01_ROBBER"), true, "")
return "loading coop_test_1"
