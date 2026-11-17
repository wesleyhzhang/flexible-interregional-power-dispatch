project_root = fileparts(mfilename('fullpath'));
addpath(project_root);
cfg = SimulationSupport.defaults();
cfg.mode = "single";
cfg.scenarios = "S25_75";
cfg.targetYears = 2035;
cfg.initialSource = "template";
run_summary = run_simulation(cfg);
