classdef TimeSupport

    methods (Static)
        function time = read(input_file, target_year)
            weights = readmatrix(input_file,'Sheet','time_weights','Range','A2:F5');
            index = readmatrix(input_file,'Sheet','time_index','Range','A2:G673');
            if ~isequal(size(weights),[4 6]) || ~isequal(size(index),[672 7]) || ...
                    any(isnan(weights) | isinf(weights),'all') || any(isnan(index) | isinf(index),'all')
                error('Simulation:TimeInput','The time tables must include four weeks and 672 hours.');
            end
            if any(weights(:,1) ~= target_year) || ~isequal(weights(:,2),(1:4)') || ...
                    any(weights(:,5)-weights(:,4) ~= 167) || any(weights(:,6) <= 0) || ...
                    any(weights(:,3) ~= floor((weights(:,4)-1)/168)+1)
                error('Simulation:TimeWeights','Invalid time table year, week order or week length.');
            end
            time = struct('numPeriods',4,'periodHours',168,'numSampleDays',28, ...
                'Ntime',672,'numStorageStates',676,'dt',1,'targetYear',target_year);
            time.weekWeights = weights(:,6);
            time.dayWeights = kron(time.weekWeights,ones(7,1));
            time.hourWeights = kron(time.weekWeights,ones(168,1));
            expected_hours = reshape((weights(:,4)' + (0:167)'),[],1);
            expected_index = [(1:672)',kron((1:4)',ones(168,1)), ...
                repmat(kron((1:7)',ones(24,1)),4,1),repmat((1:24)',28,1), ...
                repmat((1:168)',4,1),expected_hours,time.hourWeights];
            if max(abs(index-expected_index),[],'all') > 1e-9 || ...
                    abs(sum(time.hourWeights)*time.dt-8760) > 1e-8
                error('Simulation:TimeIndex','The hour index and week weights must cover 8760 hours consistently.');
            end
            time.hourIndex = array2table(index,'VariableNames', ...
                {'MatrixRow','TypicalWeek','DayOfWeek','HourOfDay','HourOfWeek','SourceHour','Weight_weeks'});
            time.hourIndex.TimeStep_h = ones(672,1);
            time.signature = sprintf('4w168|year=%d|starts=%s|weights=%s',target_year, ...
                sprintf('%d,',weights(:,4)),sprintf('%.17g,',time.weekWeights));
        end

        function [shape,annual_load,daily_load] = contractShape(load_curve,time)

            num_bus = size(load_curve,2);
            daily_load = reshape(sum(reshape(load_curve,24,time.numSampleDays,num_bus),1),time.numSampleDays,num_bus);
            annual_load = daily_load' * time.dayWeights;
            shape = zeros(time.Ntime,num_bus);
            for j = 1:num_bus
                if annual_load(j) > 0
                    shape(:,j) = kron(daily_load(:,j)/(24*annual_load(j)),ones(24,1));
                end
            end
        end

        function writeIndex(time,provinces,result_file)
            writetable(time.hourIndex,result_file,'Sheet','time_index');
            num_bus = numel(provinces);
            receiver = repelem(string(provinces(:)),time.Ntime,1);
            sample = repmat(time.hourIndex.MatrixRow,num_bus,1);
            flow_index = table((1:time.Ntime*num_bus)',receiver,sample, ...
                repmat(time.hourIndex.TypicalWeek,num_bus,1), ...
                repmat(time.hourIndex.DayOfWeek,num_bus,1), ...
                repmat(time.hourIndex.HourOfDay,num_bus,1), ...
                repmat(time.hourWeights,num_bus,1), ...
                'VariableNames',{'MatrixRow','Receiver','SampleHour','TypicalWeek','DayOfWeek','HourOfDay','Weight_weeks'});
            writetable(flow_index,result_file,'Sheet','flow_time_index');
            writecell([{'Column','Sender'};num2cell((1:num_bus)'),cellstr(string(provinces(:)))], ...
                result_file,'Sheet','flow_sender_columns');
        end
    end
end
