import re
import sys

lifecycle_path, layout_path, core_path = sys.argv[1:]
lifecycle = open(lifecycle_path).read()
layout = open(layout_path).read()
core = open(core_path).read()
layout_method = re.search(
    r"override public func layout\(\) \{(.*?)\n    \}", layout, re.S
)
required_layout_parts = (
    "Fastra-Patch: initiales Fensterlayout kurz bündeln",
    "DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)",
    "self.initialLayoutWindowGeneration == generation",
    "self.hasCompletedLayoutInCurrentWindow = true",
)
if (layout_method is None
        or any(part not in layout_method.group(1) for part in required_layout_parts)
        or layout.count("Fastra-Patch: initiales Fensterlayout kurz bündeln") != 1):
    raise SystemExit(
        f"{layout_path}: gebündeltes Startlayout hat NICHT vollstaendig gegriffen"
    )
if (core.count("var hasScheduledInitialLayoutInCurrentWindow: Bool = false") != 1
        or core.count("var initialLayoutWindowGeneration: Int = 0") != 1):
    raise SystemExit(
        f"{core_path}: Startlayout-Zustand hat NICHT vollstaendig gegriffen"
    )
if (lifecycle.count("hasScheduledInitialLayoutInCurrentWindow = false") != 1
        or lifecycle.count("initialLayoutWindowGeneration &+= 1") != 1):
    raise SystemExit(
        f"{lifecycle_path}: Startlayout-Reset hat NICHT vollstaendig gegriffen"
    )
