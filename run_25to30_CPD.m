project_root = fileparts(mfilename('fullpath'));
addpath(project_root);
cfg = SimulationSupport.defaults();
cfg.mode = "single";
cfg.scenarios = "CPD";
cfg.targetYears = 2030;
cfg.initialSource = "template";
run_summary = run_simulation(cfg);
