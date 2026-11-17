classdef ExchangeSupport

    methods (Static)
        function exchange = read(path,provinces,load_curve,time,target_year,fixed_domestic)
            names = string(provinces(:));
            num_bus = numel(names);
            exchange = struct('domesticAnnual',zeros(num_bus),'domesticImport',zeros(time.Ntime,num_bus), ...
                'domesticExport',zeros(time.Ntime,num_bus),'externalImport',zeros(time.Ntime,num_bus), ...
                'externalExport',zeros(time.Ntime,num_bus),'fixedDomestic',fixed_domestic);
            records = readtable(path,'Sheet','boundary_annual','TextType','string');
            selected = records(records.Year==target_year,:);
            if isempty(selected)
                error('Simulation:BoundaryInput','Missing international exchange data for %d.',target_year);
            end
            for r = 1:height(selected)
                province = SimulationSupport.normalizeProvince(selected.Province(r));
                j = find(names==province);
                energy = selected.Energy_MWh(r);
                if numel(j)~=1 || ~isnumeric(energy) || isnan(energy) || isinf(energy) || energy<0
                    error('Simulation:BoundaryInput','Invalid province or annual MWh for international exchange.');
                end
                if selected.Direction(r)=="import"
                    exchange.externalImport(:,j) = exchange.externalImport(:,j)+energy/8760;
                elseif selected.Direction(r)=="export"
                    exchange.externalExport(:,j) = exchange.externalExport(:,j)+energy/8760;
                else
                    error('Simulation:BoundaryDirection','Direction must be import or export.');
                end
            end
            exchange.boundaryRecords = selected;
            exchange.externalNetExport = exchange.externalExport-exchange.externalImport;
            exchange.receiverShape = zeros(time.Ntime,num_bus);
            if fixed_domestic
                raw = readcell(path,'Sheet',sprintf('domestic_%d',target_year),'Range','A1:AE31');
                row_names = strings(num_bus,1); col_names = strings(num_bus,1);
                for j = 1:num_bus
                    row_names(j) = SimulationSupport.normalizeProvince(raw{j+1,1});
                    col_names(j) = SimulationSupport.normalizeProvince(raw{1,j+1});
                end
                if ~isequal(row_names,names) || ~isequal(col_names,names)
                    error('Simulation:ExchangeProvinces','Province order differs in the annual exchange matrix.');
                end
                Q = cell2mat(raw(2:31,2:31));
                if any(isnan(Q) | isinf(Q) | Q<0,'all') || any(diag(Q)~=0)
                    error('Simulation:ExchangeEnergy','Annual interprovincial MWh must be finite and nonnegative with a zero diagonal.');
                end
                [shape,annual_load] = TimeSupport.contractShape(load_curve,time);
                if any(annual_load<=0 & sum(Q,1)'>0)
                    error('Simulation:ExchangeShape','A receiving province has zero load and positive annual imports.');
                end
                exchange.domesticAnnual = Q;
                exchange.receiverShape = shape;

                exchange.domesticExport = shape * Q';
                exchange.domesticImport = shape .* sum(Q,1);
            end
            exchange.netExport = exchange.domesticExport-exchange.domesticImport+exchange.externalNetExport;
        end

        function writeReport(exchange,time,provinces,result_file)
            writematrix(exchange.externalImport,result_file,'Sheet','external_import_MW');
            writematrix(exchange.externalExport,result_file,'Sheet','external_export_MW');
            writetable(exchange.boundaryRecords,result_file,'Sheet','external_annual_MWh');
            if exchange.fixedDomestic
                Q = exchange.domesticAnnual;
                header = [{'Sender/Receiver'},provinces];
                writecell([header;provinces(:),num2cell(Q)],result_file,'Sheet','CPD_domestic_annual_MWh');
                flow = zeros(time.Ntime*numel(provinces),numel(provinces));
                for j = 1:numel(provinces)
                    rows = (j-1)*time.Ntime+(1:time.Ntime);
                    flow(rows,:) = exchange.receiverShape(:,j)*Q(:,j)';
                end
                writematrix(flow,result_file,'Sheet','CPD_domestic_flow_MW');
                writematrix(exchange.domesticImport,result_file,'Sheet','domestic_import_MW');
                writematrix(exchange.domesticExport,result_file,'Sheet','domestic_export_MW');
            end
        end
    end
end
