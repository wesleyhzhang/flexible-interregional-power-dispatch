classdef StorageSupport

    methods (Static)
        function tag = cycleTag()
            tag = 'weekly_half_capacity_endpoints_4w_v3';
        end

        function report = summarize(provinces, time, technologies)

            provinces = string(provinces(:));
            num_weeks = time.numPeriods;
            num_bus = numel(provinces);
            num_hours = time.Ntime;
            dt = time.dt;
            hour_weights = time.hourWeights;
            report = struct();
            report.cycleTag = StorageSupport.cycleTag();
            report.provinces = provinces;
            report.tags = string(technologies(:,1));
            report.names = string(technologies(:,2));
            report.states = cell(size(technologies,1),1);
            report.annual = table();
            report.national = table();
            report.hourWeights = time.hourIndex;
            report.stateIndex = table((1:time.numStorageStates)', ...
                kron((1:num_weeks)',ones(169,1)), repmat((0:168)',num_weeks,1), ...
                'VariableNames', {'MatrixRow','TypicalWeek','HourBoundary'});

            for k = 1:size(technologies,1)
                P_ch = technologies{k,3};
                P_dis = technologies{k,4};
                E = technologies{k,5};
                if ~isequal(size(P_ch),[num_hours num_bus]) || ...
                        ~isequal(size(P_dis),[num_hours num_bus]) || ...
                        ~isequal(size(E),[time.numStorageStates num_bus])
                    error('Simulation:StorageOutputShape', 'Output dimensions do not match for %s storage.', report.names(k));
                end
                values = [P_ch(:);P_dis(:);E(:)];
                if ~isnumeric(values) || ~isreal(values) || any(isnan(values) | isinf(values))
                    error('Simulation:StorageOutput', 'Invalid output values for %s storage.', report.names(k));
                end

                charge = (hour_weights' * P_ch)' * dt;
                discharge = (hour_weights' * P_dis)' * dt;
                annual = table(provinces, repmat(report.names(k),num_bus,1), ...
                    charge, discharge, charge-discharge, discharge-charge, ...
                    'VariableNames', {'Province','Storage','Charge_MWh','Discharge_MWh', ...
                    'Loss_MWh','NetInjection_MWh'});
                national = table(report.names(k), sum(charge), sum(discharge), ...
                    sum(charge-discharge), sum(discharge-charge), ...
                    'VariableNames', {'Storage','Charge_MWh','Discharge_MWh','Loss_MWh','NetInjection_MWh'});
                report.states{k} = E;
                if k == 1
                    report.annual = annual;
                    report.national = national;
                else
                    report.annual = [report.annual;annual];
                    report.national = [report.national;national];
                end
            end
            total = table("Total", sum(report.annual.Charge_MWh), sum(report.annual.Discharge_MWh), ...
                sum(report.annual.Loss_MWh), sum(report.annual.NetInjection_MWh), ...
                'VariableNames', report.national.Properties.VariableNames);
            report.national = [report.national;total];
            report.metadata = { ...
                'Parameter','Value'; ...
                'storage_cycle',report.cycleTag; ...
                'Energy states','169 boundary states per week, with half-full endpoints'; ...
                'Initial energy','Half of total energy capacity at both endpoints'; ...
                'Power unit','MW. Hourly power values are unweighted.'; ...
                'Energy unit','MWh. Annual energy is the sum of hourly power times week weights and one hour.'; ...
                'Energy state weighting','Energy states are unweighted.'; ...
                'Weighted annual hours',sum(hour_weights)*dt; ...
                'Time step (h)',dt; ...
                'Efficiency','Multiply charging by eta and divide discharging by eta. Round-trip efficiency is eta squared.'; ...
                'Net injection','Discharge minus charge'};
            for k = 1:size(technologies,1)
                report.metadata(end+1,:) = {char(report.names(k)+" duration (h)"), technologies{k,7}};
                report.metadata(end+1,:) = {char(report.names(k)+" one-way efficiency"), technologies{k,8}};
            end
        end

        function writeReport(report, result_file)

            writetable(report.annual, result_file, 'Sheet','storage_annual_MWh');
            writetable(report.national, result_file, 'Sheet','storage_national_MWh');
            writetable(report.hourWeights, result_file, 'Sheet','typical_hour_weights');
            writetable(report.stateIndex, result_file, 'Sheet','storage_state_index');
            writecell(report.metadata, result_file, 'Sheet','storage_metadata');
            header = [{'Typical week','Hour boundary'},cellstr(report.provinces(:))'];
            for k = 1:numel(report.states)
                data = [num2cell(report.stateIndex.TypicalWeek), ...
                    num2cell(report.stateIndex.HourBoundary),num2cell(report.states{k})];
                writecell([header;data], result_file, ...
                    'Sheet',char("E_"+report.tags(k)+"_MWh"));
            end
        end
    end
end
