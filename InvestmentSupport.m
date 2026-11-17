classdef InvestmentSupport

    methods (Static)
        function tag = policyTag()
            tag = 'post2024_cohort_annuity_v1';
        end

        function ledger = emptyLedger()
            ledger = table('Size',[0 9], ...
                'VariableTypes',{'string','string','double','double','double','double','double','string','string'}, ...
                'VariableNames',{'Province','Technology','CommissionYear','LifeYears','AddedCapacity_MW', ...
                'UpfrontCost_million','AnnualCost_million','SourceScenario','SourceCase'});
        end

        function ledger = validate(ledger,target_year)
            prototype = InvestmentSupport.emptyLedger();
            required = prototype.Properties.VariableNames;
            if ~istable(ledger) || ~all(ismember(required,ledger.Properties.VariableNames))
                error('Simulation:InvestmentLedger','Required historical investment fields are missing.');
            end
            ledger = ledger(:,required);
            if height(ledger)==0
                ledger = InvestmentSupport.emptyLedger();
                return;
            end
            for field = ["Province","Technology","SourceScenario","SourceCase"]
                ledger.(field) = string(ledger.(field));
                ledger.(field)(ismissing(ledger.(field))) = "";
            end
            numeric_fields = {'CommissionYear','LifeYears','AddedCapacity_MW','UpfrontCost_million','AnnualCost_million'};
            numbers = ledger{:,numeric_fields};
            if ~isnumeric(numbers) || ~isreal(numbers) || any(isnan(numbers) | isinf(numbers),'all') || ...
                    any(ledger.CommissionYear<=2024 | ledger.CommissionYear>target_year) || ...
                    any(ledger.LifeYears<=0 | mod(ledger.LifeYears,1)~=0) || ...
                    any(mod(ledger.CommissionYear,1)~=0) || any(numbers(:,3:5)<-1e-6,'all')
                error('Simulation:InvestmentLedgerValues','Invalid investment year, lifetime, capacity or cost.');
            end
            ledger{:,numeric_fields(3:5)} = max(numbers(:,3:5),0);
            [all_names,keep] = SimulationSupport.provinceLayout();
            for r = 1:height(ledger)
                if ledger.Province(r) ~= "National"
                    ledger.Province(r) = SimulationSupport.normalizeProvince(ledger.Province(r));
                end
            end
            if any(~ismember(ledger.Province,[all_names(keep);"National"])) || ...
                    any(~ismember(ledger.Technology,["wind","pv","pumped_storage","battery","thermal","hydrogen","transmission"]))
                error('Simulation:InvestmentLedgerLabels','Invalid historical investment province or technology.');
            end
            keys = ledger.Province+"|"+ledger.Technology+"|"+string(ledger.CommissionYear);
            if numel(unique(keys))~=height(ledger)
                error('Simulation:InvestmentLedgerDuplicate','Duplicate investment for the same province, technology and construction year.');
            end
        end

        function [total,by_province] = historical(ledger,target_year,provinces)
            ledger = InvestmentSupport.validate(ledger,target_year);
            active = ledger.CommissionYear<=target_year & target_year<ledger.CommissionYear+ledger.LifeYears;
            total = sum(ledger.AnnualCost_million(active));
            by_province = zeros(numel(provinces),1);
            for i = 1:numel(provinces)
                by_province(i) = sum(ledger.AnnualCost_million(active & ledger.Province==string(provinces{i})));
            end
        end

        function report = summarize(opts,provinces,added,unit_costs,factors,lifetimes, ...
                line_annual,line_life,line_factor,operating,penalty)
            ledger = InvestmentSupport.validate(opts.investmentLedger,opts.targetYear);
            if any(ledger.CommissionYear>=opts.targetYear)
                error('Simulation:InvestmentHistoryYear','The historical ledger already includes current-period investments.');
            end
            if ~isequal(size(added),[numel(provinces) 6]) || any(isnan(added) | isinf(added) | added < -1e-6,'all')
                error('Simulation:NewInvestment','Invalid new capacity for the six technologies.');
            end
            added = max(added,0);
            technologies = ["wind","pv","pumped_storage","battery","thermal","hydrogen"];
            current = InvestmentSupport.emptyLedger();
            num_bus = numel(provinces);
            for k = 1:6
                upfront = added(:,k)*unit_costs(k);
                row = table(string(provinces(:)),repmat(technologies(k),num_bus,1), ...
                    repmat(opts.targetYear,num_bus,1),repmat(lifetimes(k),num_bus,1), ...
                    added(:,k),upfront,upfront*factors(k), ...
                    repmat(string(opts.scenario),num_bus,1),repmat(string(opts.caseTag),num_bus,1), ...
                    'VariableNames',current.Properties.VariableNames);
                current = [current;row];
            end
            if isnan(line_annual) || isinf(line_annual) || line_annual < -1e-6
                error('Simulation:LineInvestment','Invalid current annualized transmission investment.');
            end
            line_annual = max(line_annual,0);
            line = table("National","transmission",opts.targetYear,line_life,0,line_annual/line_factor,line_annual, ...
                string(opts.scenario),string(opts.caseTag),'VariableNames',current.Properties.VariableNames);
            current = [current;line];
            [historical,~] = InvestmentSupport.historical(ledger,opts.targetYear,provinces);
            current_total = sum(current.AnnualCost_million);
            total = current_total+historical+operating+penalty;
            report = struct();
            report.ledger = InvestmentSupport.validate([ledger;current],opts.targetYear);
            report.costs = table(opts.targetYear,current_total,historical,current_total+historical, ...
                operating,penalty,total,'VariableNames',{'TargetYear','CurrentNewAnnualized_million', ...
                'HistoricalActiveAnnualized_million','TotalInvestmentAnnualized_million', ...
                'Operating_million','Penalty_million','TotalSystemCost_million'});

            report.provinceCurrent=zeros(num_bus,6);
            report.provinceHistorical=zeros(num_bus,6);
            for i=1:num_bus
                for k=1:6
                    selected=report.ledger.Province==string(provinces{i}) & ...
                        report.ledger.Technology==technologies(k);
                    active=selected & report.ledger.CommissionYear<=opts.targetYear & ...
                        opts.targetYear<report.ledger.CommissionYear+report.ledger.LifeYears;
                    report.provinceCurrent(i,k)=sum(report.ledger.AnnualCost_million( ...
                        active & report.ledger.CommissionYear==opts.targetYear));
                    report.provinceHistorical(i,k)=sum(report.ledger.AnnualCost_million( ...
                        active & report.ledger.CommissionYear<opts.targetYear));
                end
            end
            report.provinceTotal=report.provinceCurrent+report.provinceHistorical;
            categories=[technologies,"transmission"]';
            new_cost=zeros(7,1); existing_cost=zeros(7,1);
            for k=1:7
                active=report.ledger.Technology==categories(k) & ...
                    report.ledger.CommissionYear<=opts.targetYear & ...
                    opts.targetYear<report.ledger.CommissionYear+report.ledger.LifeYears;
                new_cost(k)=sum(report.ledger.AnnualCost_million(active & report.ledger.CommissionYear==opts.targetYear));
                existing_cost(k)=sum(report.ledger.AnnualCost_million(active & report.ledger.CommissionYear<opts.targetYear));
            end
            report.technologyCosts=table(categories,new_cost,existing_cost,new_cost+existing_cost, ...
                'VariableNames',{'Technology','CurrentNewAnnualized_million', ...
                'HistoricalActiveAnnualized_million','TotalInvestmentAnnualized_million'});
            report.provinceTechnologyCosts=table(repmat(string(provinces(:)),6,1), ...
                repelem(technologies(:),num_bus),report.provinceCurrent(:), ...
                report.provinceHistorical(:),report.provinceTotal(:), ...
                'VariableNames',{'Province','Technology','CurrentNewAnnualized_million', ...
                'HistoricalActiveAnnualized_million','TotalInvestmentAnnualized_million'});
        end

        function writeReport(report,target_year,result_file,output_file)
            ledger = report.ledger;
            ledger.ExpiryYear = ledger.CommissionYear+ledger.LifeYears;
            ledger.ActiveAtTargetYear = ledger.CommissionYear<=target_year & target_year<ledger.ExpiryYear;
            ledger.AnnualChargeAtTarget_million = ledger.AnnualCost_million.*ledger.ActiveAtTargetYear;
            writetable(ledger,result_file,'Sheet','investment_ledger');
            writetable(report.costs,result_file,'Sheet','annual_cost_summary');
            writetable(ledger,output_file,'Sheet','investment_ledger');
            writetable(report.costs,output_file,'Sheet','annual_cost_summary');
            writetable(report.technologyCosts,result_file,'Sheet','technology_cost_summary');
            writetable(report.technologyCosts,output_file,'Sheet','technology_cost_summary');
            writetable(report.provinceTechnologyCosts,result_file,'Sheet','province_technology_costs');
            writetable(report.provinceTechnologyCosts,output_file,'Sheet','province_technology_costs');
        end
    end
end
