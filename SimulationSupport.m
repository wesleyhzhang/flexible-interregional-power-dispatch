classdef SimulationSupport

    methods (Static)
        function cfg = defaults()
            cfg = struct('scenarios', ["CPD","MCD","SMCD","S25","S50","S75"], ...
                'mode', "chain", 'targetYears', [2025 2030 2035], ...
                'MIPGap', 0.0005, 'Threads', 2, 'continueOnError', true, ...
                'initialSource', "template", 'checkpointBatch', "", ...
                'loadMultiplier', 1, 'coalPriceMultiplier', 1, 'caseTag', "");
        end

        function [all_provinces, keep_idx] = provinceLayout()
            all_provinces = ["Beijing";"Tianjin";"Hebei";"Shanxi";"Inner Mongolia";"Liaoning";"Jilin";"Heilongjiang"; ...
                "Shanghai";"Jiangsu";"Zhejiang";"Anhui";"Fujian";"Jiangxi";"Shandong";"Henan"; ...
                "Hubei";"Hunan";"Guangdong";"Guangxi";"Hainan";"Chongqing";"Sichuan";"Guizhou"; ...
                "Yunnan";"Tibet";"Shaanxi";"Gansu";"Qinghai";"Ningxia";"Xinjiang"];
            keep_idx = [1:25 27:31];
        end

        function name = normalizeProvince(value)
            if ~(ischar(value) || (isstring(value) && isscalar(value)))
                name = "";
                return;
            end
            name = strtrim(string(value));
            if ismissing(name)
                name = "";
                return;
            end
        end

        function layout = existingCapacityLayout(target_year)

            layout = struct('range','A1:S32','capacityColumns',[2 3 4 5 6 19], ...
                'lowerBoundColumns',[]);
            layout.letters = {'B','C','D','E','F','S'};
            if target_year == 2025

                layout.range = 'A1:U32';
                layout.capacityColumns = [2 3 4 5 8 21];
                layout.lowerBoundColumns = [6 7];
                layout.letters = {'B','C','D','E','H','U'};
            end

            layout.dataColumns = layout.capacityColumns-1;
            layout.lowerBoundDataColumns = layout.lowerBoundColumns-1;
        end

        function tag = baselineStorageSchema()
            tag = 'storage2024_existing_2025_total_min_v1';
        end

        function cfg = normalizeConfig(cfg)
            if ~isstruct(cfg) || ~isscalar(cfg)
                error('Simulation:Config', 'Configuration must be a scalar struct.');
            end
            defaults = SimulationSupport.defaults();
            names = fieldnames(cfg);
            for k = 1:numel(names)
                if ~isfield(defaults, names{k})
                    error('Simulation:Config', 'Unknown configuration field: %s', names{k});
                end
            end
            names = fieldnames(defaults);
            for k = 1:numel(names)
                if ~isfield(cfg, names{k})
                    cfg.(names{k}) = defaults.(names{k});
                end
            end
            scenarios = upper(strtrim(string(cfg.scenarios)));
            if isempty(scenarios) || any(ismissing(scenarios), 'all')
                error('Simulation:Config', 'Select at least one scenario.');
            end
            expanded = strings(1, 0);
            for k = 1:numel(scenarios)
                if scenarios(k) == "ALL"
                    expanded = [expanded, defaults.scenarios];
                elseif scenarios(k) == "S25_75"
                    expanded = [expanded, "S25", "S50", "S75"];
                else
                    expanded(end+1) = scenarios(k);
                end
            end
            cfg.scenarios = unique(expanded, 'stable');
            if any(~ismember(cfg.scenarios, defaults.scenarios))
                error('Simulation:Config', 'Supported scenarios are CPD, MCD, SMCD, S25, S50 and S75.');
            end
            cfg.mode = lower(string(cfg.mode));
            cfg.initialSource = lower(string(cfg.initialSource));
            if ~isscalar(cfg.mode) || ismissing(cfg.mode) || ~ismember(cfg.mode, ["chain","single"])
                error('Simulation:Config', 'mode must be chain or single.');
            end
            if ~isscalar(cfg.initialSource) || ismissing(cfg.initialSource) || ...
                    ~ismember(cfg.initialSource, ["template","checkpoint"])
                error('Simulation:Config', 'initialSource must be template or checkpoint.');
            end
            years = cfg.targetYears;
            if ~isnumeric(years) || ~isreal(years) || ~isvector(years) || isempty(years) || ...
                    any(~ismember(years, [2025 2030 2035])) || any(diff(years(:)) <= 0)
                error('Simulation:Config', 'Select target years from 2025, 2030 and 2035 in ascending order.');
            end
            cfg.targetYears = years(:)';
            if cfg.mode == "single" && numel(years) ~= 1
                error('Simulation:Config', 'Single-stage mode requires exactly one target year.');
            end
            if cfg.mode == "chain" && any(diff(cfg.targetYears) ~= 5)
                error('Simulation:Config', 'Chain mode requires consecutive stages. Use single for one stage.');
            end
            validateattributes(cfg.MIPGap, {'numeric'}, {'real','finite','scalar','>=',0,'<',1});
            validateattributes(cfg.Threads, {'numeric'}, {'real','finite','scalar','integer','positive'});
            validateattributes(cfg.loadMultiplier, {'numeric'}, {'real','finite','scalar','positive'});
            validateattributes(cfg.coalPriceMultiplier, {'numeric'}, {'real','finite','scalar','positive'});
            cfg.caseTag = upper(strtrim(string(cfg.caseTag)));
            if ~isscalar(cfg.caseTag) || ismissing(cfg.caseTag) || ...
                    (strlength(cfg.caseTag) > 0 && ...
                    isempty(regexp(char(cfg.caseTag), '^[A-Z0-9_-]+$', 'once')))
                error('Simulation:Config', 'caseTag can be empty or contain letters, digits, underscores and hyphens.');
            end
            if ~islogical(cfg.continueOnError) || ~isscalar(cfg.continueOnError)
                error('Simulation:Config', 'continueOnError must be true or false.');
            end
            cfg.checkpointBatch = string(cfg.checkpointBatch);
            if ~isscalar(cfg.checkpointBatch) || ismissing(cfg.checkpointBatch)
                error('Simulation:Config', 'checkpointBatch must be a batch directory name.');
            end
            if cfg.initialSource == "checkpoint" && cfg.targetYears(1) > 2025 && ...
                    (strlength(cfg.checkpointBatch) == 0 || ...
                    isempty(regexp(char(cfg.checkpointBatch), '^[A-Za-z0-9_-]+$', 'once')))
                error('Simulation:Config', 'Specify a valid checkpoint batch directory name.');
            end
        end

        function opts = modelOptions(cfg, scenario, target_year, batch_id)
            root = fileparts(mfilename('fullpath'));
            scenario = upper(string(scenario));
            opts = struct('scenario', scenario, 'targetYear', target_year, ...
                'MIPGap', cfg.MIPGap, 'Threads', cfg.Threads, 'alphaFlex', NaN, ...
                'scenarioTag', '', 'existSheet', 'exist', ...
                'loadMultiplier', cfg.loadMultiplier, ...
                'coalPriceMultiplier', cfg.coalPriceMultiplier, 'caseTag', cfg.caseTag, ...
                'storageCycle', StorageSupport.cycleTag(), ...
                'investmentPolicy', InvestmentSupport.policyTag(), ...
                'investmentLedger', InvestmentSupport.emptyLedger());
            opts.existLayout = SimulationSupport.existingCapacityLayout(target_year);
            opts.baselineStorageSchema = SimulationSupport.baselineStorageSchema();
            if target_year == 2025
                opts.scenario = "BASE";
                input_dir = '202507';
                input_name = 'input_data_4w_2024_v11.xlsx';
                opts.modelFunction = 'model_24to25_CPD';
            else
                if target_year == 2030
                    period = '25to30';
                    if scenario == "CPD"
                        input_dir = '203007';
                        input_name = 'input_data_4w_2025_v11.xlsx';
                    else
                        input_dir = '2030';
                        input_name = 'input_data_4w_2025_v8.xlsx';
                    end
                elseif target_year == 2035
                    period = '30to35';
                    if scenario == "CPD"
                        input_dir = '203507';
                        input_name = 'input_data_4w_2030_v11.xlsx';
                    elseif scenario == "SMCD"
                        input_dir = '2035';
                        input_name = 'input_data_4w_2030_v8_flexible.xlsx';
                    else
                        input_dir = '2035';
                        input_name = 'input_data_4w_2030_v8_contract.xlsx';
                    end
                else
                    error('Simulation:Year', 'Unsupported target year.');
                end
                if ismember(scenario, ["S25","S50","S75"])
                    opts.modelFunction = ['model_' period '_S25_75'];
                    switch scenario
                        case "S25"
                            opts.alphaFlex = 0.25;
                            opts.scenarioTag = 'alpha025';
                        case "S50"
                            opts.alphaFlex = 0.50;
                            opts.scenarioTag = 'alpha05';
                        case "S75"
                            opts.alphaFlex = 0.75;
                            opts.scenarioTag = 'alpha075';
                    end
                    if target_year == 2035
                        opts.existSheet = ['exist_' opts.scenarioTag];
                    end
                else
                    opts.modelFunction = ['model_' period '_' char(scenario)];
                end
            end
            opts.inputDir = fullfile(root, 'input_templates', input_dir);
            opts.templateFile = fullfile(opts.inputDir, input_name);
            opts.runInputDir = fullfile(root, 'run_inputs', char(batch_id), ...
                char(opts.scenario), num2str(target_year));
            opts.inputFile = fullfile(opts.runInputDir, input_name);
            opts.exchangeTemplateFile = fullfile(root,'input_templates','annual_exchange.xlsx');
            opts.exchangeFile = fullfile(opts.runInputDir,'annual_exchange.xlsx');
            opts.outputDir = fullfile(root, 'outputs', char(batch_id), ...
                char(opts.scenario), num2str(target_year));
            opts.outputFile = fullfile(opts.outputDir, ['capacity_' num2str(target_year) '.xlsx']);
            opts.matrixFile = fullfile(opts.outputDir, ['matrices_' num2str(target_year) '.xlsx']);
            opts.checkpointFile = fullfile(opts.outputDir, 'checkpoint.mat');
            opts.solverLog = fullfile(opts.outputDir, 'gurobi.log');
        end

        function opts = prepareInput(opts, incoming_state)

            dependencies = {'DR_Cost.xlsx','Coal_Rate.xlsx'};
            if opts.scenario ~= "BASE" && opts.scenario ~= "CPD"
                dependencies = [dependencies, {'line_AC.xlsx','line_DC.xlsx', ...
                    'line_AC_with_candidate.xlsx','line_DC_with_candidate.xlsx'}];
            end
            for k = 1:numel(dependencies)
                path = fullfile(opts.inputDir, dependencies{k});
                if ~isfile(path)
                    error('Simulation:InputMissing', 'Missing auxiliary input: %s', path);
                end
            end
            if ~isfile(opts.templateFile)
                error('Simulation:InputMissing', 'Missing input template: %s', opts.templateFile);
            end
            if isfile(opts.inputFile)
                error('Simulation:InputExists', 'Run input already exists: %s', opts.inputFile);
            end
            if ~isfolder(opts.runInputDir)
                mkdir(opts.runInputDir);
            end
            [ok, message] = copyfile(opts.templateFile, opts.inputFile);
            if ~ok
                error('Simulation:InputCopy', '%s', message);
            end
            for k = 1:numel(dependencies)
                [ok,message] = copyfile(fullfile(opts.inputDir,dependencies{k}), ...
                    fullfile(opts.runInputDir,dependencies{k}));
                if ~ok
                    error('Simulation:AuxiliaryCopy','%s',message);
                end
            end
            [ok,message] = copyfile(opts.exchangeTemplateFile,opts.exchangeFile);
            if ~ok
                error('Simulation:ExchangeCopy','%s',message);
            end
            opts.time = TimeSupport.read(opts.inputFile,opts.targetYear);
            if isempty(incoming_state)
                ledger = readtable(opts.inputFile,'Sheet','investment_ledger','TextType','string');
                opts.investmentLedger = InvestmentSupport.validate(ledger,opts.targetYear);
                if opts.targetYear>2025 && isempty(opts.investmentLedger)
                    error('Simulation:MissingInvestmentHistory', ...
                        'The template needs an investment_ledger. Supply one, use a checkpoint, or run from 2025.');
                end
            end
            layout = opts.existLayout;
            raw = readcell(opts.inputFile, 'Sheet', opts.existSheet, 'Range', layout.range);
            required_columns = max([layout.capacityColumns,layout.lowerBoundColumns]);
            if size(raw, 1) < 32 || size(raw, 2) < required_columns
                error('Simulation:InputLayout', 'The capacity sheet requires headers and all 31 province rows: %s/%s', ...
                    opts.inputFile, opts.existSheet);
            end
            [all_provinces, keep_idx] = SimulationSupport.provinceLayout();
            for k = keep_idx
                actual = SimulationSupport.normalizeProvince(raw{k+1, 1});
                if actual ~= all_provinces(k)
                    error('Simulation:ProvinceLayout', ...
                        'Capacity row %d must contain %s, found %s. Keep the original 31-province order including Tibet.', ...
                        k+1, all_provinces(k), actual);
                end
            end
            tibet_name = SimulationSupport.normalizeProvince(raw{27, 1});
            if tibet_name ~= "" && tibet_name ~= "Tibet"
                error('Simulation:TibetRow', 'Keep row 27 for Tibet. The row may be blank.');
            end
            excel_cols = layout.capacityColumns;
            expected_headers = ["wind","pv","pump_stroage","battery_storage","thermal","hydrogen_storage"];
            for k = 1:numel(excel_cols)
                header = lower(strtrim(string(raw{1, excel_cols(k)})));
                if ~isscalar(header) || ismissing(header) || ~startsWith(header, expected_headers(k))
                    error('Simulation:InputHeader', 'Unexpected capacity header in column %d.', excel_cols(k));
                end
            end
            lower_headers = ["pump_stroage","battery_storage"];
            for k = 1:numel(layout.lowerBoundColumns)
                c = layout.lowerBoundColumns(k);
                header = lower(strtrim(string(raw{1,c})));
                if ~isscalar(header) || ismissing(header) || ~startsWith(header,lower_headers(k))
                    error('Simulation:StorageLowerBoundHeader', ...
                        'Unexpected 2025 storage minimum header in column %d.',c);
                end
            end
            if ~isempty(incoming_state)
                source_year = 2025;
                source_scenario = "BASE";
                if opts.targetYear == 2035
                    source_year = 2030;
                    source_scenario = opts.scenario;
                end
                incoming_state = SimulationSupport.validateState( ...
                    incoming_state, source_year, source_scenario);
                opts.investmentLedger = incoming_state.investmentLedger;

                letters = layout.letters;
                for k = 1:numel(letters)
                    writecell(num2cell(incoming_state.capacity(1:25, k)), opts.inputFile, ...
                        'Sheet', opts.existSheet, 'Range', [letters{k} '2'], 'UseExcel', false);
                    writecell(num2cell(incoming_state.capacity(26:30, k)), opts.inputFile, ...
                        'Sheet', opts.existSheet, 'Range', [letters{k} '28'], 'UseExcel', false);
                    raw(keep_idx+1, excel_cols(k)) = num2cell(incoming_state.capacity(:, k));
                end
            end

            for r = keep_idx+1
                for c = [excel_cols,layout.lowerBoundColumns]
                    value = raw{r, c};
                    if ~isnumeric(value) || ~isscalar(value) || ~isreal(value) || ...
                            (isnan(value) || isinf(value)) || value < 0
                        error('Simulation:InputCapacity', ...
                            'Capacity at row %d, column %d must be finite and nonnegative in MW.', r, c);
                    end
                end
            end
            if any(opts.investmentLedger.CommissionYear>=opts.targetYear)
                error('Simulation:InvestmentHistoryYear','Historical investment must precede the target year.');
            end
            writetable(opts.investmentLedger,opts.inputFile,'Sheet','investment_ledger');
            opts.inputDir = opts.runInputDir;
        end

        function result = emptyResult(opts)
            result = struct('status', 'not_started', 'solver_problem', NaN, ...
                'message', '', 'objective', NaN, 'runtime_seconds', NaN, ...
                'output_file', opts.outputFile, 'matrix_file', opts.matrixFile, 'state', []);
        end

        function state = capacityState(provinces, capacity, opts, ledger)
            state = struct('schemaVersion', 2, 'year', opts.targetYear, ...
                'scenario', opts.scenario, 'unit', 'MW', ...
                'provinces', string(provinces(:)), ...
                'columns', ["wind","pv","pumped_storage","battery","thermal","hydrogen"], ...
                'capacity', capacity, 'investmentLedger', ledger, ...
                'storageCycle',StorageSupport.cycleTag(), ...
                'annualLoadPolicy',AnnualLoadSupport.policyTag(), ...
                'investmentPolicy', InvestmentSupport.policyTag(), 'timeSignature', opts.time.signature, ...
                'baselineStorageSchema', opts.baselineStorageSchema);
            state = SimulationSupport.validateState(state, opts.targetYear, opts.scenario);
        end

        function state = validateState(state, expected_year, expected_scenario)
            required = {'schemaVersion','year','scenario','unit','provinces','columns','capacity', ...
                'investmentLedger','investmentPolicy','timeSignature', ...
                'storageCycle','annualLoadPolicy'};
            if ~isstruct(state) || ~isscalar(state) || ~all(isfield(state, required))
                error('Simulation:State', 'Incomplete capacity state.');
            end
            if ~isequal(state.schemaVersion, 2) || ~isequal(state.year, expected_year) || ...
                    ~isequal(string(state.scenario), string(expected_scenario)) || ...
                    ~isequal(string(state.unit), "MW")
                error('Simulation:StateSource', 'Capacity state year, scenario, unit or version differs from this stage.');
            end
            if ~isfield(state,'baselineStorageSchema') || ...
                    ~isequal(string(state.baselineStorageSchema),string(SimulationSupport.baselineStorageSchema()))
                error('Simulation:StateStorageBaseline', ...
                    'Checkpoint uses a different storage baseline. Restart from 2025.');
            end
            if ~strcmp(string(state.storageCycle),string(StorageSupport.cycleTag())) || ...
                    ~strcmp(string(state.annualLoadPolicy),string(AnnualLoadSupport.policyTag()))
                error('Simulation:StatePhysicalPolicy','Checkpoint uses a different load or storage policy. Restart from 2025.');
            end
            if ~isequal(string(state.investmentPolicy),string(InvestmentSupport.policyTag())) || ...
                    ~isscalar(string(state.timeSignature)) || ~startsWith(string(state.timeSignature),'4w168|')
                error('Simulation:StatePolicy','Checkpoint uses a different time axis or investment policy. Restart from 2025.');
            end
            state.investmentLedger = InvestmentSupport.validate(state.investmentLedger,expected_year);
            columns = ["wind","pv","pumped_storage","battery","thermal","hydrogen"];
            if ~isequal(string(state.columns(:))', columns)
                error('Simulation:StateColumns', 'Capacity state has an unexpected technology order.');
            end
            labels = string(state.provinces(:));
            for k = 1:numel(labels)
                labels(k) = SimulationSupport.normalizeProvince(labels(k));
            end
            [all_provinces, keep_idx] = SimulationSupport.provinceLayout();
            expected = all_provinces(keep_idx);
            [found, order] = ismember(expected, labels);
            if numel(labels) ~= 30 || numel(unique(labels)) ~= 30 || ~all(found)
                error('Simulation:StateProvinces', 'Capacity state must contain the 30 modeled provinces in order.');
            end
            capacity = state.capacity;
            if ~isnumeric(capacity) || ~isreal(capacity) || ~isequal(size(capacity), [30 6]) || ...
                    any(isnan(capacity) | isinf(capacity), 'all') || any(capacity < -1e-6, 'all')
                error('Simulation:StateCapacity', 'Capacity state must be a finite, nonnegative 30-by-6 matrix.');
            end
            state.capacity = max(capacity(order, :), 0);
            state.provinces = expected;
            state.columns = columns;
        end
    end
end
