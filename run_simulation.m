function [run_summary, batch_id] = run_simulation(cfg, return_partial)

if nargin < 2
    return_partial = false;
end
cfg = SimulationSupport.normalizeConfig(cfg);
root = fileparts(mfilename('fullpath'));
addpath(root);
requirements = {'gurobi'};
for k = 1:numel(requirements)
    if exist(requirements{k}, 'file') == 0
        error('Simulation:Dependency', 'Add %s to the MATLAB path.', requirements{k});
    end
end

batch_id = char(datetime('now', 'TimeZone', 'Asia/Shanghai', 'Format', 'yyyyMMdd_HHmmss_SSS'));
if strlength(cfg.caseTag) > 0
    batch_id = [batch_id '_' char(cfg.caseTag)];
end
base_id = batch_id;
suffix = 0;
while isfolder(fullfile(root, 'outputs', batch_id)) || ...
        isfolder(fullfile(root, 'run_inputs', batch_id))
    suffix = suffix + 1;
    batch_id = sprintf('%s_%d', base_id, suffix);
end
batch_dir = fullfile(root, 'outputs', batch_id);
mkdir(batch_dir);
storage_cycle = StorageSupport.cycleTag();
investment_policy = InvestmentSupport.policyTag();
save(fullfile(batch_dir, 'run_config.mat'), 'cfg', 'batch_id', 'storage_cycle', 'investment_policy');
log_file = fullfile(batch_dir, 'run_log.txt');
append_log(log_file, sprintf('Batch %s, scenarios %s, target years %s, MIPGap %.8g', ...
    batch_id, strjoin(cfg.scenarios, ','), mat2str(cfg.targetYears), cfg.MIPGap));
append_log(log_file, sprintf('Case %s, load multiplier %.8g, coal price multiplier %.8g. Workbooks store unscaled load.', ...
    cfg.caseTag, cfg.loadMultiplier, cfg.coalPriceMultiplier));
append_log(log_file, sprintf('Storage policy %s. Each week starts and ends at half capacity. Annual energy uses week weights.', storage_cycle));
append_log(log_file, 'Post-2024 additions retain their original annualized cost over their lifetime. Existing 2024 capacity is excluded.');

rows = struct([]);
states = containers.Map('KeyType', 'char', 'ValueType', 'any');
stop_requested = false;
for year_idx = 1:numel(cfg.targetYears)
    target_year = cfg.targetYears(year_idx);
    if target_year == 2025
        scenarios = "BASE";
    else
        scenarios = cfg.scenarios;
    end
    for scenario_idx = 1:numel(scenarios)
        scenario = scenarios(scenario_idx);
        opts = SimulationSupport.modelOptions(cfg, scenario, target_year, batch_id);
        row = summary_row(opts);
        incoming_state = [];
        stage_timer = tic;
        try

            if year_idx > 1
                source_key = char(scenario);
                if target_year == 2030
                    source_key = 'BASE';
                end
                if ~isKey(states, source_key)
                    row.status = 'skipped';
                    row.message = 'Skipped because the previous stage failed.';
                    row.source = 'blocked_by_previous_stage';
                else
                    incoming_state = states(source_key);
                    row.source = sprintf('current_batch/%s/%d', source_key, incoming_state.year);
                end
            elseif target_year > 2025 && cfg.initialSource == "checkpoint"
                [incoming_state, source_file] = load_checkpoint(root, cfg, scenario, target_year);
                row.source = source_file;
            else
                row.source = 'template';
            end

            if ~strcmp(row.status, 'skipped')
                fprintf('\n========== %s: %d to %d ==========\n', scenario, start_year(target_year), target_year);
                append_log(log_file, sprintf('Starting %s/%d with capacity from %s', scenario, target_year, row.source));
                if ~isfolder(opts.outputDir)
                    mkdir(opts.outputDir);
                end
                opts = SimulationSupport.prepareInput(opts, incoming_state);
                result = feval(opts.modelFunction, opts);
                row.runtime_seconds = toc(stage_timer);
                row.status = result.status;
                row.solver_problem = result.solver_problem;
                row.message = result.message;
                row.objective = result.objective;
                if strcmp(result.status, 'success')
                    state = SimulationSupport.validateState(result.state, target_year, scenario);
                    checkpoint = struct('schemaVersion', 2, 'status', 'success', ...
                        'batchId', batch_id, 'state', state, 'config', cfg, ...
                        'options', opts, 'source', row.source, 'objective', result.objective, ...
                        'storageCycle', storage_cycle, 'investmentPolicy', investment_policy, ...
                        'timeSignature', opts.time.signature);

                    save(opts.checkpointFile, 'checkpoint');
                    states(char(scenario)) = state;
                    row.checkpoint_file = opts.checkpointFile;
                    totals = sum(state.capacity, 1);
                    row.wind_MW = totals(1);
                    row.pv_MW = totals(2);
                    row.pumped_storage_MW = totals(3);
                    row.battery_MW = totals(4);
                    row.thermal_MW = totals(5);
                    row.hydrogen_MW = totals(6);
                    row.current_investment_annual_million = result.investmentSummary.CurrentNewAnnualized_million;
                    row.historical_investment_annual_million = result.investmentSummary.HistoricalActiveAnnualized_million;
                    row.total_investment_annual_million = result.investmentSummary.TotalInvestmentAnnualized_million;
                end
            end
        catch exception
            row.status = 'error';
            row.runtime_seconds = toc(stage_timer);
            row.message = sprintf('%s: %s', exception.identifier, exception.message);
            if ~isfolder(opts.outputDir)
                mkdir(opts.outputDir);
            end
            write_error(fullfile(opts.outputDir, 'error_details.txt'), exception);
        end
        if ~strcmp(row.status, 'success') && isKey(states, char(scenario))
            remove(states, char(scenario));
        end

        text_fields = {'scenario','status','case_tag','storage_cycle','message','source','input_file', ...
            'exist_sheet','output_file','matrix_file','checkpoint_file'};
        for text_idx = 1:numel(text_fields)
            row.(text_fields{text_idx}) = string(row.(text_fields{text_idx}));
        end
        if isempty(rows)
            rows = row;
        else
            rows(end+1) = row;
        end
        append_log(log_file, sprintf('%s/%d: %s - %s', scenario, target_year, row.status, row.message));
        run_summary = struct2table(rows);

        save(fullfile(batch_dir, 'run_summary.mat'), 'run_summary');
        try
            writetable(run_summary, fullfile(batch_dir, 'run_summary.xlsx'), 'Sheet', 'summary');
        catch summary_exception
            append_log(log_file, sprintf('Excel summary could not be written. MAT summary saved. %s', summary_exception.message));
        end
        if ~cfg.continueOnError && ~strcmp(row.status, 'success')
            stop_requested = true;
            break;
        end
    end
    if stop_requested
        break;
    end
end
fprintf('\nBatch complete: %s\nOutput folder: %s\n', batch_id, batch_dir);
disp(run_summary(:, {'scenario','target_year','status','objective','runtime_seconds'}));
if stop_requested && ~return_partial
    error('Simulation:Stopped', 'Run stopped after a failed stage. See %s.', batch_dir);
end
end

function row = summary_row(opts)
row = struct('scenario', char(opts.scenario), 'storage_cycle', string(opts.storageCycle), ...
    'start_year', start_year(opts.targetYear), ...
    'target_year', opts.targetYear, 'status', 'not_started', ...
    'case_tag', string(opts.caseTag), 'load_multiplier', opts.loadMultiplier, ...
    'coal_price_multiplier', opts.coalPriceMultiplier, ...
    'solver_problem', NaN, 'objective', NaN, 'runtime_seconds', NaN, ...
    'wind_MW', NaN, 'pv_MW', NaN, 'pumped_storage_MW', NaN, ...
    'battery_MW', NaN, 'thermal_MW', NaN, 'hydrogen_MW', NaN, ...
    'current_investment_annual_million', NaN, 'historical_investment_annual_million', NaN, ...
    'total_investment_annual_million', NaN, ...
    'message', '', 'source', '', 'input_file', opts.inputFile, ...
    'exist_sheet', opts.existSheet, 'output_file', opts.outputFile, ...
    'matrix_file', opts.matrixFile, 'checkpoint_file', '');
end

function year = start_year(target_year)
if target_year == 2025
    year = 2024;
else
    year = target_year - 5;
end
end

function [state, source_file] = load_checkpoint(root, cfg, scenario, target_year)
source_year = target_year - 5;
source_scenario = scenario;
if source_year == 2025
    source_scenario = "BASE";
end
source_file = fullfile(root, 'outputs', char(cfg.checkpointBatch), ...
    char(source_scenario), num2str(source_year), 'checkpoint.mat');
if ~isfile(source_file)
    error('Simulation:CheckpointMissing', 'Checkpoint file is missing: %s', source_file);
end
loaded = load(source_file, 'checkpoint');
if ~isfield(loaded, 'checkpoint') || ~isstruct(loaded.checkpoint) || ...
        ~isscalar(loaded.checkpoint) || ...
        ~all(isfield(loaded.checkpoint, {'schemaVersion','status','state'})) || ...
        ~isequal(loaded.checkpoint.schemaVersion, 2) || ...
        ~strcmp(loaded.checkpoint.status, 'success')
    error('Simulation:CheckpointInvalid', 'Checkpoint does not record a completed stage: %s', source_file);
end
if ~isfield(loaded.checkpoint, 'storageCycle') || ...
        ~isequal(string(loaded.checkpoint.storageCycle), string(StorageSupport.cycleTag()))
    error('Simulation:CheckpointStorageCycle', ...
        'Checkpoint uses a different storage policy. Restart from the 2025 baseline: %s', source_file);
end
if ~isfield(loaded.checkpoint,'investmentPolicy') || ...
        ~isequal(string(loaded.checkpoint.investmentPolicy),string(InvestmentSupport.policyTag()))
    error('Simulation:CheckpointInvestmentPolicy','Checkpoint uses a different investment policy: %s',source_file);
end
state = SimulationSupport.validateState(loaded.checkpoint.state, source_year, source_scenario);
source_opts = SimulationSupport.modelOptions(cfg,source_scenario,source_year,'validation');
source_time = TimeSupport.read(source_opts.templateFile,source_year);
if ~isequal(string(state.timeSignature),string(source_time.signature))
    error('Simulation:CheckpointTime','Checkpoint time index or weights differ from the current inputs: %s',source_file);
end

if source_year == 2030
    if ~isfield(loaded.checkpoint, 'config')
        error('Simulation:CheckpointConfig', '2030 checkpoint has no configuration for load and coal price multipliers: %s', source_file);
    end
    source_cfg = SimulationSupport.normalizeConfig(loaded.checkpoint.config);
    if source_cfg.loadMultiplier ~= cfg.loadMultiplier || ...
            source_cfg.coalPriceMultiplier ~= cfg.coalPriceMultiplier
        error('Simulation:CheckpointFactors', ...
            '2030 checkpoint has different load or coal price multipliers: %s', source_file);
    end
end
end

function append_log(path, message)
fid = fopen(path, 'a', 'n', 'UTF-8');
if fid < 0
    error('Simulation:Log', 'Could not write the run log: %s', path);
end
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, '[%s] %s\n', char(datetime('now','TimeZone','Asia/Shanghai', ...
    'Format','yyyy-MM-dd HH:mm:ss')), message);
fprintf('%s\n', message);
end

function write_error(path, exception)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0
    return;
end
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', getReport(exception, 'extended', 'hyperlinks', 'off'));
end
