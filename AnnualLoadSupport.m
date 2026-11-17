classdef AnnualLoadSupport

    methods (Static)
        function tag = policyTag()
            tag = 'weighted_typical_4w_annual_v1';
        end

        function [curve,annual,report] = prepare(opts,provinces,raw_curve,time)
            curve = raw_curve*opts.loadMultiplier;
            original = (time.hourWeights(:)'*raw_curve)'*time.dt;
            annual = (time.hourWeights(:)'*curve)'*time.dt;
            report = struct('annual_MWh',annual, ...
                'metadata',struct('source_file',opts.inputFile,'source_sheet','load', ...
                'source_range','B1:YW31','unit','MWh','policy',AnnualLoadSupport.policyTag()), ...
                'table',table(string(provinces(:)),original, ...
                repmat(opts.loadMultiplier,numel(annual),1),annual, ...
                'VariableNames',{'Province','UnscaledWeighted4w_MWh','LoadMultiplier','ModelAnnual_MWh'}));
            fprintf('%d weighted annual load: multiplier %.4g, total %.9g MWh.\n', ...
                opts.targetYear,opts.loadMultiplier,sum(annual));
        end

        function writeReport(report,result_file,output_file)
            for path={result_file,output_file}
                writetable(report.table,path{1},'Sheet','annual_load_MWh');
                m=report.metadata;
                writecell({'Parameter','Value';'source_file',m.source_file;'source_sheet',m.source_sheet; ...
                    'source_range',m.source_range;'unit',m.unit;'policy',m.policy; ...
                    'Method','Sum hourly load times week weight and one hour. Apply the load multiplier once.'}, ...
                    path{1},'Sheet','annual_load_source');
            end
        end
    end
end
