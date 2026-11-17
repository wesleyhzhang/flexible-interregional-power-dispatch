function result = model_30to35_SMCD(cfg)

model_timer = tic;

result = SimulationSupport.emptyResult(cfg);
filePath = cfg.inputDir;
input_file = cfg.inputFile;
exist_sheet = cfg.existSheet;

provinces = {'Beijing', 'Tianjin', 'Hebei', 'Shanxi', 'Inner Mongolia', 'Liaoning', 'Jilin', 'Heilongjiang', ...
    'Shanghai', 'Jiangsu', 'Zhejiang', 'Anhui', 'Fujian', 'Jiangxi', 'Shandong', 'Henan', ...
    'Hubei', 'Hunan', 'Guangdong', 'Guangxi', 'Hainan', 'Chongqing', 'Sichuan', 'Guizhou', ...
    'Yunnan', 'Tibet', 'Shaanxi', 'Gansu', 'Qinghai', 'Ningxia', 'Xinjiang'};

keep_idx = [1:25 27:31];
provinces = provinces(keep_idx);
num_provinces = length(provinces);
bus_num = num_provinces;
time = cfg.time;
num_typical_days = time.numSampleDays;
Ntime = time.Ntime;
week_weights = time.weekWeights;
day_weights = time.dayWeights;
hour_weights = time.hourWeights;

titles = {'Province', 'New wind capacity', 'New solar PV capacity', ...
    'New thermal capacity', 'Reserved thermal 1', 'Reserved thermal 2', 'Reserved thermal 3', 'Reserved thermal 4', 'Reserved thermal 5', ...
    'Total thermal capacity', 'Reserved total thermal 1', 'Reserved total thermal 2', 'Reserved total thermal 3', 'Reserved total thermal 4', 'Reserved total thermal 5', ...
    'Carbon emissions (tonnes)', 'VRE generation used', 'Total wind capacity', 'Total solar PV capacity', 'Wind potential', 'Solar PV potential', 'Year', ...
    'Wind unit investment cost', 'Solar PV unit investment cost','Total annualized investment', 'Operating cost', 'Renewable integration penalty', 'Total system cost', 'Fuel cost', ...
    'Load shedding cost','New battery capacity','New pumped storage capacity','New hydrogen storage capacity','Battery unit investment cost','Pumped storage unit investment cost','Wind investment','Solar PV investment','Thermal investment', ...
    'Mean thermal load factor while online',  'Reserved LF2', 'Reserved LF3', 'Reserved LF4', 'Reserved LF5', 'Reserved LF6', ...
    'Startup and shutdown cost', 'Total pumped storage capacity','Total battery capacity','Total hydrogen storage capacity'};

titles = [titles, {'Current annualized investment','Active historical annualized investment', ...
    'Total annualized battery investment','Total annualized pumped storage investment','Total annualized hydrogen storage investment', ...
    'Current annualized wind investment','Active historical annualized wind investment','Current annualized solar PV investment','Active historical annualized solar PV investment', ...
    'Current annualized pumped storage investment','Active historical annualized pumped storage investment','Current annualized battery investment','Active historical annualized battery investment', ...
    'Current annualized thermal investment','Active historical annualized thermal investment','Current annualized hydrogen storage investment','Active historical annualized hydrogen storage investment'}];
all_results = cell(num_provinces, numel(titles));

%% Input data
data_exist     = xlsread(input_file, exist_sheet);
data_potential = xlsread(input_file,'potential');
data_output    = xlsread(input_file,'power_output');
data_hydro     = xlsread(input_file, 'hydro');
data_RPS       = xlsread(input_file,'RPS');
data_load      = xlsread(input_file,'load');
data_cfwind    = xlsread(input_file,'cf_wind');
data_cfpv      = xlsread(input_file,'cf_pv');

DR_costs       = xlsread(fullfile(filePath,'DR_Cost.xlsx'),'DR_Costs');
data_exist     = data_exist(keep_idx, :);
data_potential = data_potential(keep_idx, :);
data_output    = data_output(keep_idx, :);
data_hydro     = data_hydro(keep_idx, :);
data_RPS       = data_RPS(keep_idx, :);
data_load      = data_load(keep_idx, :);
data_cfwind    = data_cfwind(keep_idx, :);
data_cfpv      = data_cfpv(keep_idx, :);

DR_costs       = DR_costs(keep_idx, :);

I_gen_exist = data_exist(1:bus_num,5);
I_wind_exist = data_exist(1:bus_num,1);
I_pv_exist   = data_exist(1:bus_num,2);
I_ps_exist   = data_exist(1:bus_num,3);
I_bat_exist  = data_exist(1:bus_num,4);
I_hes_exist  = data_exist(1:bus_num,18);

poten_wind = data_potential(1:bus_num,1);
poten_pv   = data_potential(1:bus_num,2);
poten_ps   = data_potential(1:bus_num,3);

P_nuclear = data_output(1:bus_num,2);
hydro_power = data_hydro(1:bus_num,:);

RPS_vec = data_RPS(1:bus_num,1);

c_shed_vec  = DR_costs(1:bus_num,1)/10^6;

[load,annual_load,annual_load_report] = AnnualLoadSupport.prepare( ...
    cfg,provinces,data_load(1:bus_num,:)',time);
P_fwind  = data_cfwind(1:bus_num,:)';
P_fpv    = data_cfpv(1:bus_num,:)';

exchange = ExchangeSupport.read(cfg.exchangeFile, provinces, load, time, cfg.targetYear, false);
external_net_export = exchange.externalNetExport;

%% Thermal parameters
[~, ~, coal_rate_data] = xlsread(fullfile(filePath, 'Coal_Rate.xlsx'), 'Sheet1');
[~, coal_province_idx] = ismember(provinces, coal_rate_data(2:end, 1));
p_coal    = cell2mat(coal_rate_data(coal_province_idx(:) + 1, 4));
c_gen     = 4025000/10^6;
alpha_min = 0.25;
RU_ratio  = 0.2;
RD_ratio  = 0.2;
minup     = 8;
mindown   = 8;
up_perMW   = 1000/10^6;
down_perMW = 1000/10^6;
initstate  = 0;

c_coal = (0.546/10^6) * cfg.coalPriceMultiplier;
c_tax  = 0.356/10^6;
e_coal = 2.4;

%% Investment costs
a_pv=0.08;
a_wind=0.08;
a_gen=0.08;
y_pv=15;
y_wind=15;
y_gen=40;
k_pv=(a_pv*(1+a_pv)^y_pv)/((1+a_pv)^y_pv-1);
k_wind=(a_wind*(1+a_wind)^y_wind)/((1+a_wind)^y_wind-1);
k_gen=(a_gen*(1+a_gen)^y_gen)/((1+a_gen)^y_gen-1);
c_pv=2700000/10^6;
c_wind=3888000/10^6;
a_bat=0.08;
a_ps=0.08;
y_bat=15;
y_ps=50;
k_bat=(a_bat*(1+a_bat)^y_bat)/((1+a_bat)^y_bat-1);
k_ps=(a_ps*(1+a_ps)^y_ps)/((1+a_ps)^y_ps-1);
y_hes = 25;
a_hes = 0.08;
k_hes = (a_hes*(1+a_hes)^y_hes)/((1+a_hes)^y_hes-1);

%% Storage parameters
e_bat = 0.90;
e_ps = 0.75;
e_hes = 0.5;
c_bat = 1200000/10^6;
c_ps = 5000000/10^6;
c_hes = 2850000/10^6;

M1=10^3;
M2=10^3;

%% Transmission parameters
data_distance_AC = xlsread(fullfile(filePath,'line_AC.xlsx'),'distance');
data_distance_AC = data_distance_AC(1:bus_num,1:bus_num);
data_distance_AC(isnan(data_distance_AC)) = 0;
c_line_exist_AC = xlsread(fullfile(filePath,'line_AC_with_candidate.xlsx'),'line');
c_line_exist_AC = c_line_exist_AC(1:bus_num,1:bus_num);
c_line_exist_AC(isnan(c_line_exist_AC)) = 0;

data_distance_DC = xlsread(fullfile(filePath,'line_DC.xlsx'),'distance');
data_distance_DC = data_distance_DC(1:bus_num,1:bus_num);
data_distance_DC(isnan(data_distance_DC)) = 0;
c_line_exist_DC = xlsread(fullfile(filePath,'line_DC_with_candidate.xlsx'),'line');
c_line_exist_DC = c_line_exist_DC(1:bus_num,1:bus_num);
c_line_exist_DC(isnan(c_line_exist_DC)) = 0;

line_loss_rate_per_km = 0.0032 / 100;
line_efficiency_AC = (1 - line_loss_rate_per_km) .^ data_distance_AC;
line_efficiency_AC(1:bus_num+1:end) = 1;
line_efficiency_AC = max(line_efficiency_AC, 0);
line_loss_rate_AC = 1 - line_efficiency_AC;

line_efficiency_DC = (1 - line_loss_rate_per_km) .^ data_distance_DC;
line_efficiency_DC(1:bus_num+1:end) = 1;
line_efficiency_DC = max(line_efficiency_DC, 0);
line_loss_rate_DC = 1 - line_efficiency_DC;
c_unit_line = 4000/1e6;
c_unit_conv = 1480000/1e6;
a_line = 0.08;
y_line = 40;
k_line = (a_line*(1+a_line)^y_line)/((1+a_line)^y_line-1);

alpha_flex = 1;
[contract_shape,contract_annual_load] = TimeSupport.contractShape(load,time);
%% Linear program

C_line_AC = triu(c_line_exist_AC,1);
C_line_AC = C_line_AC+C_line_AC';
C_line_DC = c_line_exist_DC;
C_line_DC(1:bus_num+1:end) = 0;
C_line_new_AC = C_line_AC-c_line_exist_AC;
C_line_new_DC = C_line_DC-c_line_exist_DC;
c_line_cost_AC = k_line*c_unit_line*sum(sum(C_line_new_AC.*data_distance_AC))/2;
c_conv_cost_AC = k_line*c_unit_conv*sum(sum(C_line_new_AC));
c_line_cost_DC = k_line*c_unit_line*sum(sum(C_line_new_DC.*data_distance_DC));
c_conv_cost_DC = k_line*c_unit_conv*sum(sum(C_line_new_DC));
c_inv_line = c_line_cost_AC+c_conv_cost_AC+c_line_cost_DC+c_conv_cost_DC;
[c_inv_historical,historical_by_province] = InvestmentSupport.historical( ...
    cfg.investmentLedger,cfg.targetYear,provinces);
RPS_target = 0.332;

planning = struct();
planning.network_mode = 'flexible';
planning.time = time;
planning.load = load;
planning.weighted_annual_load = annual_load;
planning.wind_cf = P_fwind;
planning.pv_cf = P_fpv;
planning.hydro = hydro_power';
planning.nuclear = P_nuclear(:);
planning.external_net_export = external_net_export;
planning.existing = [I_wind_exist,I_pv_exist,I_ps_exist,I_bat_exist,I_gen_exist,I_hes_exist];
planning.potential = [poten_wind,poten_pv,poten_ps];
planning.alpha = alpha_flex;
planning.contract_shape = contract_shape;
planning.contract_annual_load = contract_annual_load;
planning.capacity_ac = c_line_exist_AC;
planning.capacity_dc = c_line_exist_DC;
planning.efficiency_ac = line_efficiency_AC;
planning.efficiency_dc = line_efficiency_DC;
planning.capacity_cost = [c_wind*k_wind,c_pv*k_pv,c_ps*k_ps,c_bat*k_bat,c_gen*k_gen,c_hes*k_hes];
planning.fuel_cost_per_MWh = p_coal(:)*c_coal;
planning.tax_cost_per_MWh = p_coal(:)*e_coal*c_tax;
planning.shed_cost_per_MWh = c_shed_vec(:);
planning.eta = [e_ps,e_bat,e_hes];
planning.duration = [8,2,100];
planning.alpha_min = alpha_min;
planning.RU = RU_ratio;
planning.RD = RD_ratio;
planning.rps = RPS_target;
planning.constant_cost = c_inv_historical+c_inv_line;

sol = CompactPlanningSupport.solve(planning,cfg);
result.solver_problem = sol.problem;
result.message = sol.message;
result.compact_statistics = sol.statistics;
if sol.problem ~= 0
    result.status = 'solver_failed';
    result.runtime_seconds = toc(model_timer);
    fprintf(2,'[%s/%d] Solve failed (code %d): %s\n', ...
        cfg.scenario,cfg.targetYear,sol.problem,sol.message);
    return;
end
s = sol.solution;

%% Restore results
I_wind_val = s.investment(:,1);
I_pv_val = s.investment(:,2);
I_ps_val = s.investment(:,3);
I_bat_val = s.investment(:,4);
I_gen_val = s.investment(:,5);
I_hes_val = s.investment(:,6);
P_pv_val = s.pv;
P_wind_val = s.wind;
P_hydro_val = s.hydro;
P_shed_val = s.shed;
P_gen_val = s.generation;
P_nuclear_val = repmat(P_nuclear(:)',Ntime,1);
P_chaps_val = s.charge{1};
P_disps_val = s.discharge{1};
E_ps_val = s.energy{1};
P_chabat_val = s.charge{2};
P_disbat_val = s.discharge{2};
E_bat_val = s.energy{2};
P_chahes_val = s.charge{3};
P_dishes_val = s.discharge{3};
E_hes_val = s.energy{3};
P_chaps_h = P_chaps_val;
P_disps_h = P_disps_val;
P_chabat_h = P_chabat_val;
P_disbat_h = P_disbat_val;
P_chahes_h = P_chahes_val;
P_dishes_h = P_dishes_val;
P_net_bat = P_disbat_h-P_chabat_h;
P_net_ps = P_disps_h-P_chaps_h;
P_net_hes = P_dishes_h-P_chahes_h;
storage_technologies = {
    'bat','Battery',P_chabat_h,P_disbat_h,E_bat_val,I_bat_exist+I_bat_val,2,e_bat;
    'ps','Pumped storage',P_chaps_h,P_disps_h,E_ps_val,I_ps_exist+I_ps_val,8,e_ps;
    'hes','Hydrogen storage',P_chahes_h,P_dishes_h,E_hes_val,I_hes_exist+I_hes_val,100,e_hes
};
storage_report = StorageSupport.summarize(provinces,time,storage_technologies);
C_line_AC_val = s.Cac;
C_line_DC_val = s.Cdc;
C_line_val = C_line_AC_val+C_line_DC_val;
P_line_AC_val = s.Pac;
P_line_DC_val = s.Pdc;
P_line_val = P_line_AC_val+P_line_DC_val;
P_line_p_val = s.net_injection';
Q_transfer_annual_val = s.Qannual;
Q_transfer_sample_val = zeros(bus_num,bus_num);
Q_fixed_annual_val = zeros(bus_num,bus_num);
Q_flex_annual_val = zeros(bus_num,bus_num);
Q_fixed_sample_val = zeros(bus_num,bus_num);
Q_flex_sample_val = zeros(bus_num,bus_num);
P_line_fixed_val = zeros(size(P_line_val));
P_line_flex_val = zeros(size(P_line_val));
for i = 1:bus_num
    for j = 1:bus_num
        idx_ij = (j-1)*Ntime+(1:Ntime);
        P_line_fixed_val(i,idx_ij) = (1-alpha_flex)*Q_transfer_annual_val(i,j)*contract_shape(:,j)';
        P_line_flex_val(i,idx_ij) = P_line_val(i,idx_ij)-P_line_fixed_val(i,idx_ij);
        Q_transfer_sample_val(i,j) = sum(P_line_val(i,idx_ij));
        Q_fixed_annual_val(i,j) = P_line_fixed_val(i,idx_ij)*hour_weights;
        Q_flex_annual_val(i,j) = P_line_flex_val(i,idx_ij)*hour_weights;
        Q_fixed_sample_val(i,j) = sum(P_line_fixed_val(i,idx_ij));
        Q_flex_sample_val(i,j) = sum(P_line_flex_val(i,idx_ij));
    end
end
P_line_AC_delivered_val = zeros(size(P_line_AC_val));
P_line_DC_delivered_val = zeros(size(P_line_DC_val));
P_line_AC_loss_val = zeros(size(P_line_AC_val));
P_line_DC_loss_val = zeros(size(P_line_DC_val));
for i = 1:bus_num
    for j = 1:bus_num
        if i == j
            continue;
        end
        idx_ij = (j-1)*Ntime+(1:Ntime);
        P_line_AC_delivered_val(i,idx_ij) = line_efficiency_AC(i,j)*P_line_AC_val(i,idx_ij);
        P_line_DC_delivered_val(i,idx_ij) = line_efficiency_DC(i,j)*P_line_DC_val(i,idx_ij);
        P_line_AC_loss_val(i,idx_ij) = line_loss_rate_AC(i,j)*P_line_AC_val(i,idx_ij);
        P_line_DC_loss_val(i,idx_ij) = line_loss_rate_DC(i,j)*P_line_DC_val(i,idx_ij);
    end
end
P_line_delivered_val = P_line_AC_delivered_val+P_line_DC_delivered_val;
P_line_loss_val = P_line_AC_loss_val+P_line_DC_loss_val;

E_gen_annual = hour_weights'*P_gen_val;
thermal_fuel_cost_val = E_gen_annual*p_coal*c_coal;
tax_cost_val = E_gen_annual*p_coal*e_coal*c_tax;
thermal_updown_cost_val = 0;
shed_cost_val = (hour_weights'*P_shed_val)*c_shed_vec;
total_var = thermal_fuel_cost_val+tax_cost_val+shed_cost_val;
c_inv_current = sum(I_pv_val)*c_pv*k_pv+sum(I_wind_val)*c_wind*k_wind ...
    +sum(I_bat_val)*c_bat*k_bat+sum(I_ps_val)*c_ps*k_ps ...
    +sum(I_hes_val)*c_hes*k_hes+sum(I_gen_val)*k_gen*c_gen+c_inv_line;
c_inv_val = c_inv_current+c_inv_historical;
c_res_val = 1e6*s.Q_res;
c_total_val = total_var+c_inv_val+c_res_val;
carbon_emission_val = E_gen_annual*p_coal*e_coal/1000;
Total_Demand_val = sum(hour_weights'*(load-P_shed_val+external_net_export));
line_annual_val = c_inv_line;
line_life_val = y_line;
line_factor_val = k_line;
investment_report = InvestmentSupport.summarize(cfg,provinces, ...
    [I_wind_val,I_pv_val,I_ps_val,I_bat_val,I_gen_val,I_hes_val], ...
    [c_wind,c_pv,c_ps,c_bat,c_gen,c_hes], ...
    [k_wind,k_pv,k_ps,k_bat,k_gen,k_hes], ...
    [y_wind,y_pv,y_ps,y_bat,y_gen,y_hes], ...
    line_annual_val,line_life_val,line_factor_val,total_var,c_res_val);

%% Provincial summaries

for i = 1:bus_num
    result_I_gen       = I_gen_val(i);
    result_I_gen_exist = I_gen_exist(i);
    result_I_gen_total = I_gen_exist(i) + I_gen_val(i);

    result_I_wind_total = I_wind_exist(i)+I_wind_val(i);
    result_I_pv_total   = I_pv_exist(i)+I_pv_val(i);

    P_val = P_gen_val(:,i);

    cap_total = result_I_gen_total;
    if cap_total > 0
        LF = P_val / cap_total;
    else
        LF = nan(Ntime,1);
    end

    valid_LF = ~isnan(LF);
    if any(valid_LF)
        avg_LF_on = sum(hour_weights(valid_LF) .* LF(valid_LF)) ...
            / sum(hour_weights(valid_LF));
    else
        avg_LF_on = NaN;
    end

    VRE_i    = sum(hour_weights .* (P_pv_val(:,i) + P_wind_val(:,i)));
    demand_i = sum(hour_weights .* (load(:,i) - P_shed_val(:,i) + external_net_export(:,i)));
    if demand_i > 0
        grid_connection_i = VRE_i / demand_i;
    else
        grid_connection_i = NaN;
    end

    carbon_i = sum(hour_weights .* (P_gen_val(:,i))) * p_coal(i) * e_coal / 1000;

    c_inv_wind_i = investment_report.provinceTotal(i,1);
    c_inv_pv_i = investment_report.provinceTotal(i,2);
    c_inv_ps_i = investment_report.provinceTotal(i,3);
    c_inv_bat_i = investment_report.provinceTotal(i,4);
    c_inv_gen_i = investment_report.provinceTotal(i,5);
    c_inv_hes_i = investment_report.provinceTotal(i,6);
    c_inv_current_i = sum(investment_report.provinceCurrent(i,:));
    c_inv_historical_i = sum(investment_report.provinceHistorical(i,:));
    c_inv_i = sum(investment_report.provinceTotal(i,:));

    c_fuel_i = sum(hour_weights .* (P_gen_val(:,i))) * p_coal(i) * c_coal;
    c_updown_i = 0;
    c_shed_i = c_shed_vec(i) * sum(hour_weights .* (P_shed_val(:,i)));
    c_tax_i = sum(hour_weights .* (P_gen_val(:,i))) * p_coal(i) * e_coal * c_tax;
    c_var_i = c_fuel_i + c_updown_i + c_shed_i + c_tax_i;

    if Total_Demand_val > 0
        share_load_i = demand_i / Total_Demand_val;
    else
        share_load_i = 0;
    end
    c_res_i = c_res_val * share_load_i;

    c_total_i = c_inv_i + c_var_i + c_res_i;

    %% Provincial output
    row = cell(1, numel(titles));
    row{1}  = provinces{i};
    row{2}  = I_wind_val(i);
    row{3}  = I_pv_val(i);
    row{4}  = I_gen_val(i);
    row{5}  = []; row{6} = []; row{7} = []; row{8} = []; row{9} = [];
    row{10} = result_I_gen_total;
    row{11} = []; row{12} = []; row{13} = []; row{14} = []; row{15} = [];
    row{16} = carbon_i;
    row{17} = grid_connection_i;
    row{18} = result_I_wind_total;
    row{19} = result_I_pv_total;
    row{20} = poten_wind(i);
    row{21} = poten_pv(i);
    row{22} = 2035;
    row{23} = c_wind;
    row{24} = c_pv;
    row{25} = c_inv_i;
    row{26} = c_var_i;
    row{27} = c_res_i;
    row{28} = c_total_i;
    row{29} = c_fuel_i;
    row{30} = c_shed_i;
    row{31} = I_bat_val(i);
    row{32} = I_ps_val(i);
    row{33} = I_hes_val(i);
    row{34} = c_bat;
    row{35} = c_ps;
    row{36} = c_inv_wind_i;
    row{37} = c_inv_pv_i;
    row{38} = c_inv_gen_i;
    row{39} = avg_LF_on;
    row{40} = []; row{41} = []; row{42} = []; row{43} = []; row{44} = [];
    row{45} = c_updown_i;
    row{46} = I_ps_exist(i)+I_ps_val(i);
    row{47} = I_bat_exist(i)+I_bat_val(i);
    row{48} = I_hes_exist(i)+I_hes_val(i);
    row{49} = c_inv_current_i;
    row{50} = c_inv_historical_i;
    row{51} = c_inv_bat_i; row{52} = c_inv_ps_i; row{53} = c_inv_hes_i;
    for technology = 1:6
        row{53+2*technology-1} = investment_report.provinceCurrent(i,technology);
        row{53+2*technology} = investment_report.provinceHistorical(i,technology);
    end

    all_results(i,:) = row;
end

result.state = SimulationSupport.capacityState(provinces, ...
    [I_wind_exist + I_wind_val, I_pv_exist + I_pv_val, ...
     I_ps_exist + I_ps_val, I_bat_exist + I_bat_val, ...
     I_gen_exist + I_gen_val, I_hes_exist + I_hes_val], cfg, investment_report.ledger);
all_results = [titles; all_results];
output_file = cfg.outputFile;
if ~exist(fileparts(output_file),'dir')
    mkdir(fileparts(output_file));
end
writecell(all_results, output_file);

result_file = cfg.matrixFile;
writematrix(C_line_val,   result_file, 'Sheet','C_line');
writematrix(C_line_AC_val, result_file, 'Sheet','C_line_AC');
writematrix(C_line_DC_val, result_file, 'Sheet','C_line_DC');
writematrix(P_line_p_val', result_file, 'Sheet','P_line_p');
writematrix(P_line_val', result_file, 'Sheet','P_line');
writematrix(P_line_AC_val', result_file, 'Sheet','P_line_AC');
writematrix(P_line_DC_val', result_file, 'Sheet','P_line_DC');
writematrix(P_line_delivered_val', result_file, 'Sheet','P_line_delivered');
writematrix(P_line_AC_delivered_val', result_file, 'Sheet','P_line_AC_delivered');
writematrix(P_line_DC_delivered_val', result_file, 'Sheet','P_line_DC_delivered');
writematrix(P_line_loss_val', result_file, 'Sheet','P_line_loss');
writematrix(P_line_AC_loss_val', result_file, 'Sheet','P_line_AC_loss');
writematrix(P_line_DC_loss_val', result_file, 'Sheet','P_line_DC_loss');

writematrix(P_gen_val,    result_file, 'Sheet','P_gen');
writematrix(P_pv_val,     result_file, 'Sheet','P_pv');
writematrix(P_wind_val,   result_file, 'Sheet','P_wind');
writematrix(P_shed_val,   result_file, 'Sheet','P_shed');

writematrix(P_chabat_h, result_file, 'Sheet','P_ch_bat');
writematrix(P_disbat_h, result_file, 'Sheet','P_dis_bat');
writematrix(P_chaps_h,  result_file, 'Sheet','P_ch_ps');
writematrix(P_disps_h,  result_file, 'Sheet','P_dis_ps');
writematrix(P_chahes_h, result_file, 'Sheet','P_ch_hes');
writematrix(P_dishes_h, result_file, 'Sheet','P_dis_hes');

writematrix(P_net_bat, result_file, 'Sheet','P_net_bat');
writematrix(P_net_ps,  result_file, 'Sheet','P_net_ps');
writematrix(P_net_hes, result_file, 'Sheet','P_net_hes');

StorageSupport.writeReport(storage_report, result_file);

writematrix(P_hydro_val, result_file, 'Sheet','P_hydro');
writematrix(P_nuclear_val, result_file, 'Sheet','P_nuclear');

runtime = toc(model_timer);
fprintf('Runtime: %.2f seconds\n', runtime);
disp(['Planning results saved to: ', output_file]);

TimeSupport.writeIndex(time, provinces, result_file);
ExchangeSupport.writeReport(exchange, time, provinces, result_file);
InvestmentSupport.writeReport(investment_report, cfg.targetYear, result_file, output_file);
AnnualLoadSupport.writeReport(annual_load_report,result_file,output_file);

result.investmentSummary = investment_report.costs;
result.status = 'success';
result.objective = c_total_val;
result.runtime_seconds = toc(model_timer);
end
