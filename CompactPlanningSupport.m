classdef CompactPlanningSupport

    methods (Static)
        function [model, recovery] = build(p)
            T = p.time.Ntime;
            B = size(p.load,2);
            P = p.time.periodHours;
            W = p.time.numPeriods;
            w = p.time.hourWeights(:);
            H = sum(w);
            if T ~= P*W || mod(T,24) ~= 0 || numel(w) ~= T || ...
                    any(~isfinite(w) | w <= 0) || abs(H-8760) > 1e-8
                error('Compact:Time','Invalid typical-week index or weights.');
            end
            network_mode = 'contract';
            if isfield(p,'network_mode'), network_mode = char(p.network_mode); end
            if ~ismember(network_mode,{'contract','fixed_curve','flexible','exogenous'})
                error('Compact:NetworkMode','Unknown transmission mode.');
            end
            has_contract = ismember(network_mode,{'contract','fixed_curve'});
            validateattributes(p.alpha,{'numeric'},{'real','finite','scalar','>=',0,'<=',1});
            if strcmp(network_mode,'fixed_curve') && p.alpha ~= 0
                error('Compact:Alpha','MCD requires alpha to be zero.');
            end
            values = {p.load,p.wind_cf,p.pv_cf,p.hydro,p.existing,p.potential,p.nuclear};
            for k = 1:numel(values)
                if any(~isfinite(values{k}(:)) | values{k}(:) < 0)
                    error('Compact:Input','Load, capacity factors, hydro limits and existing capacity must be finite and nonnegative.');
                end
            end
            if ~isequal(size(p.load),[T B]) || ~isequal(size(p.wind_cf),[T B]) || ...
                    ~isequal(size(p.pv_cf),[T B]) || ~isequal(size(p.hydro),[T B]) || ...
                    ~isequal(size(p.existing),[B 6]) || ~isequal(size(p.potential),[B 3])
                error('Compact:InputShape','Input dimensions do not match.');
            end
            Cac = triu(p.capacity_ac,1);
            Cac = Cac+Cac';
            Cdc = p.capacity_dc;
            Cdc(1:B+1:end) = 0;
            if strcmp(network_mode,'exogenous') && (any(Cac(:) ~= 0) || any(Cdc(:) ~= 0))
                error('Compact:ExogenousNetwork','CPD uses exogenous exchanges and cannot optimize transmission links.');
            end
            if any(~isfinite(Cac(:)) | Cac(:) < 0) || any(~isfinite(Cdc(:)) | Cdc(:) < 0)
                error('Compact:LineCapacity','Line capacity must be finite and nonnegative.');
            end
            [sender,receiver] = find(Cac > 0 | Cdc > 0);
            pair_index = sub2ind([B B],sender,receiver);
            K = numel(sender);
            ac_capacity = Cac(pair_index);
            dc_capacity = Cdc(pair_index);
            ac_efficiency = p.efficiency_ac(pair_index);
            dc_efficiency = p.efficiency_dc(pair_index);
            overlap = find(ac_capacity > 0 & dc_capacity > 0);
            J = numel(overlap);
            has_dc = dc_capacity > 0;
            base_capacity = ac_capacity;
            base_capacity(has_dc) = dc_capacity(has_dc);
            base_efficiency = ac_efficiency;
            base_efficiency(has_dc) = dc_efficiency(has_dc);
            omega = w/H;
            r = zeros(T,K);
            valid_receiver = true(K,1);
            if has_contract
                r = p.contract_shape(:,receiver)*H;
                valid_receiver = p.contract_annual_load(receiver) > 0;
            end
            if has_contract && (any(abs(omega'*r(:,valid_receiver)-1) > 1e-10) || ...
                    any(~isfinite(r(:)) | r(:) < 0))
                error('Compact:ContractShape','Contract profiles must be nonnegative and normalized over the year.');
            end

            nv = 0;
            lower = zeros(0,1);
            upper = zeros(0,1);
            inv_upper = inf(B,6);
            inv_upper(:,1:3) = p.potential-p.existing(:,1:3);
            inv_lower = zeros(B,6);
            if isfield(p,'minimum_capacity')
                validateattributes(p.minimum_capacity,{'numeric'},{'real','finite','nonnegative','size',[B 6]});
                inv_lower = max(0,p.minimum_capacity-p.existing);
            end
            v.investment = allocate(inv_upper,inv_lower);
            pv_limits = inf(T,B);
            pv_limits(p.pv_cf == 0) = 0;
            wind_limits = inf(T,B);
            wind_limits(p.wind_cf == 0) = 0;
            v.pv = allocate(pv_limits);
            v.wind = allocate(wind_limits);
            v.hydro = allocate(p.hydro);
            v.generation = allocate(inf(T,B));
            v.shed = allocate(p.load);
            v.charge = cell(1,3);
            v.discharge = cell(1,3);
            v.energy = cell(1,3);
            for k = 1:3
                v.charge{k} = allocate(inf(T,B));
                v.discharge{k} = allocate(inf(T,B));
                v.energy{k} = allocate(inf(T,B));
            end
            capacity_sum = ac_capacity+dc_capacity;
            q_upper = zeros(K,1);
            if has_contract && K > 0
                q_upper = capacity_sum;
                r_max = max(r,[],1)';
                active_shape = r_max > 0;
                q_upper(active_shape) = min(q_upper(active_shape), ...
                    capacity_sum(active_shape)./((1-p.alpha)*r_max(active_shape)));
                q_upper(~valid_receiver) = 0;
            end
            v.q = allocate(q_upper);
            flex_upper = repmat(capacity_sum(:)',T,1);
            flex_upper(:,~valid_receiver) = 0;
            if has_contract && p.alpha == 0
                flex_upper(:) = 0;
            end
            v.flex = allocate(flex_upper);
            v.ac_split = allocate(repmat(ac_capacity(overlap)',T,1));
            v.rps_deficit = allocate(inf);
            N = nv;

            blocks = {};
            rhs_blocks = {};
            sense_blocks = {};
            scale_blocks = {};
            names = {};
            block_ends = zeros(0,1);
            row_count = 0;

            add_vre(v.pv,p.pv_cf,2,'pv');
            add_vre(v.wind,p.wind_cf,1,'wind');
            daily = kron(speye(B),kron(speye(T/24),ones(1,24)));
            append(daily*pick(v.shed),0.05*daily*p.load(:),'<',1,'daily_DR');

            node = repelem((1:B)',T);
            gen_cap = v.investment(:,5);
            append(pick(v.generation)-pick(gen_cap(node)), ...
                p.existing(node,5),'<',1,'thermal_upper');
            append(-pick(v.generation)+p.alpha_min*pick(gen_cap(node)), ...
                -p.alpha_min*p.existing(node,5),'<',1,'thermal_minimum');
            preceding = zeros(W*(P-1),1);
            following = preceding;
            for k = 1:W
                positions = (k-1)*(P-1)+(1:P-1);
                hours = (k-1)*P+(1:P);
                preceding(positions) = hours(1:end-1);
                following(positions) = hours(2:end);
            end
            ramp_node = repelem((1:B)',numel(preceding));
            difference = pick(v.generation(following,:))-pick(v.generation(preceding,:));
            append(difference-p.RU*pick(gen_cap(ramp_node)), ...
                p.RU*p.existing(ramp_node,5),'<',1,'ramp_up');
            append(-difference-p.RD*pick(gen_cap(ramp_node)), ...
                p.RD*p.existing(ramp_node,5),'<',1,'ramp_down');

            next_hour = zeros(T,1);
            state_output = zeros(W*(P+1),1);
            for k = 1:W
                hours = (k-1)*P+(1:P);
                next_hour(hours) = [hours(2:end) hours(1)]';
                state_output((k-1)*(P+1)+(1:P+1)) = [hours hours(1)]';
            end
            storage_columns = [3 4 6];
            for k = 1:3
                cap = v.investment(:,storage_columns(k));
                existing = p.existing(node,storage_columns(k));
                cap_rows = pick(cap(node));
                append(pick(v.charge{k})-cap_rows,existing,'<',1,sprintf('charge_%d',k));
                append(pick(v.discharge{k})-cap_rows,existing,'<',1,sprintf('discharge_%d',k));
                append(pick(v.energy{k})-cap_rows,existing,'<',p.duration(k),sprintf('SOC_upper_%d',k));
                dynamics = pick(v.energy{k}(next_hour,:))-pick(v.energy{k}) ...
                    -p.time.dt*p.eta(k)/p.duration(k)*pick(v.charge{k}) ...
                    +p.time.dt/(p.eta(k)*p.duration(k))*pick(v.discharge{k});
                append(dynamics,zeros(T*B,1),'=',p.duration(k),sprintf('SOC_dynamics_%d',k));

                initial_node=repelem((1:B)',W);
                append(pick(v.energy{k}(1:P:T,:))-.5*pick(cap(initial_node)), ...
                    .5*p.existing(initial_node,storage_columns(k)),'=',p.duration(k), ...
                    sprintf('SOC_half_capacity_%d',k));
            end

            fixed_map = sparse((1:T*K)',repelem((1:K)',T), ...
                (1-p.alpha)*r(:),T*K,K);
            total_flow = pick(v.flex)+embed(fixed_map,v.q);
            split_map = kron(sparse(overlap,(1:J)',ones(J,1),K,J),speye(T));
            base_flow = total_flow-embed(split_map,v.ac_split);
            append(base_flow,repelem(base_capacity,T),'<',1,'line_capacity');
            overlap_rows = reshape((overlap(:)'-1)*T+(1:T)',[],1);
            append(-base_flow(overlap_rows,:),zeros(T*J,1),'<',1,'DC_nonnegative');

            if has_contract && p.alpha > 0
                append(H*(kron(speye(K),omega')*pick(v.flex)-p.alpha*pick(v.q)), ...
                    zeros(K,1),'=',1,'annual_contract');
            end

            incidence = sparse([sender;receiver],[(1:K)';(1:K)'], ...
                [-ones(K,1);base_efficiency],B,K);
            split_incidence = sparse(receiver(overlap),(1:J)', ...
                ac_efficiency(overlap)-dc_efficiency(overlap),B,J);
            net_flex = kron(incidence,speye(T));
            net_split = kron(split_incidence,speye(T));
            net_injection = embed(net_flex,v.flex)+embed(net_flex*fixed_map,v.q) ...
                +embed(net_split,v.ac_split);
            balance = pick(v.generation)+pick(v.pv)+pick(v.wind)+pick(v.hydro)+pick(v.shed) ...
                +net_injection;
            for k = 1:3
                balance = balance+pick(v.discharge{k})-pick(v.charge{k});
            end
            rhs_balance = p.load+p.external_net_export-repmat(p.nuclear(:)',T,1);
            append(balance,rhs_balance(:),'=',1,'power_balance');

            weighted_bus = repmat(w',1,B);
            storage_loss = sparse(1,N);
            for k = 1:3
                storage_loss = storage_loss+weighted_bus*(pick(v.charge{k})-pick(v.discharge{k}));
            end
            base_loss = 1-base_efficiency;
            loss_flex = kron(base_loss',w');
            loss_split = kron((dc_efficiency(overlap)-ac_efficiency(overlap))',w');
            line_loss = embed(loss_flex,v.flex)+embed(loss_flex*fixed_map,v.q) ...
                +embed(loss_split,v.ac_split);
            rps_supply = weighted_bus*(pick(v.pv)+pick(v.wind)+p.rps*pick(v.shed)) ...
                -p.rps*(storage_loss+line_loss)+pick(v.rps_deficit);
            demand_constant = sum(w'*(p.load+p.external_net_export));
            append(-rps_supply/H,-p.rps*demand_constant/H,'<',H,'RPS');

            original_obj = zeros(N,1);
            capital = repmat(p.capacity_cost(:)',B,1);
            present = v.investment ~= 0;
            original_obj(v.investment(present)) = capital(present);
            thermal = w*(p.fuel_cost_per_MWh(:)+p.tax_cost_per_MWh(:))';
            original_obj(v.generation(:)) = thermal(:);
            shed_cost = w*p.shed_cost_per_MWh(:)';
            present = v.shed ~= 0;
            original_obj(v.shed(present)) = shed_cost(present);
            original_obj(v.rps_deficit) = 1e6;
            objective_scale = 1;
            model = struct('A',vertcat(blocks{:}),'rhs',vertcat(rhs_blocks{:}), ...
                'sense',vertcat(sense_blocks{:}),'obj',original_obj/objective_scale, ...
                'lb',lower,'ub',upper,'vtype','C','modelsense','min','objcon',0);
            recovery = struct('variables',v,'sender',sender,'receiver',receiver, ...
                'pair_index',pair_index,'overlap',overlap,'Cac',Cac,'Cdc',Cdc, ...
                'incidence',incidence,'split_incidence',split_incidence, ...
                'fixed_map',fixed_map,'state_output',state_output,'H',H, ...
                'objective_scale',objective_scale,'original_obj',original_obj, ...
                'constant_cost',p.constant_cost,'row_scale',vertcat(scale_blocks{:}), ...
                'network_mode',network_mode,'has_contract',has_contract, ...
                'block_names',{names},'block_ends',block_ends,'q_upper',q_upper);

            function ids = allocate(limits,minimums)
                if nargin < 2, minimums = zeros(size(limits)); end
                if any(isnan(limits(:)) | limits(:) == -inf)
                    error('Compact:VariableBounds','Invalid variable upper bound.');
                end
                keep = limits ~= 0 | minimums ~= 0;
                ids = zeros(size(limits));
                count = nnz(keep);
                ids(keep) = nv+(1:count);
                lower = [lower;minimums(keep)];
                upper = [upper;limits(keep)];
                nv = nv+count;
            end
            function A = pick(ids)
                ids = ids(:);
                keep = ids > 0;
                A = sparse(find(keep),ids(keep),ones(nnz(keep),1),numel(ids),N);
            end
            function A = embed(coefficients,ids)
                [rr,cc,vv] = find(coefficients);
                ids = ids(:);
                keep = ids(cc) > 0;
                A = sparse(rr(keep),ids(cc(keep)),vv(keep),size(coefficients,1),N);
            end
            function append(A,b,s,physical_scale,name)
                if isempty(b)
                    return;
                end
                count = numel(b);
                if size(A,1) ~= count
                    error('Compact:RowShape','Row count mismatch in constraint block %s.',name);
                end
                blocks{end+1} = sparse(A);
                rhs_blocks{end+1} = full(b(:));
                sense_blocks{end+1} = repmat(s,count,1);
                scale_blocks{end+1} = repmat(physical_scale,count,1);
                names{end+1} = name;
                row_count = row_count+count;
                block_ends(end+1,1) = row_count;
            end
            function add_vre(ids,cf,column,name)
                active = find(ids(:) > 0);
                if isempty(active)
                    return;
                end
                column_node = ceil(active/T);
                coefficient = cf(active);
                A = pick(ids(active))-spdiags(coefficient,0,numel(active),numel(active)) ...
                    *pick(v.investment(column_node,column));
                append(A,coefficient.*p.existing(column_node,column),'<',1,name);
            end
        end

        function answer = solve(p,cfg)
            [model,recovery] = CompactPlanningSupport.build(p);
            statistics = struct('rows',size(model.A,1),'columns',size(model.A,2), ...
                'nonzeros',nnz(model.A));
            params = struct('DualReductions',0,'TuneTimeLimit',0,'MIPGap',cfg.MIPGap, ...
                'Threads',cfg.Threads,'LogFile',cfg.solverLog,'OutputFlag',1, ...
                'OptimalityTol',1e-9,'FeasibilityTol',1e-9);
            raw = gurobi(model,params);
            answer = struct('problem',CompactPlanningSupport.problemCode(raw.status), ...
                'message',['Gurobi: ' raw.status],'solution',[],'statistics',statistics);
            if answer.problem == 0
                answer.solution = CompactPlanningSupport.restore(raw.x,p,recovery);
            end
        end

        function s = restore(x,p,recovery)
            v = recovery.variables;
            T = p.time.Ntime;
            B = size(p.load,2);
            K = numel(recovery.sender);
            s.investment = extract(v.investment);
            s.pv = extract(v.pv);
            s.wind = extract(v.wind);
            s.hydro = extract(v.hydro);
            s.generation = extract(v.generation);
            s.shed = extract(v.shed);
            s.charge = cell(1,3);
            s.discharge = cell(1,3);
            s.energy = cell(1,3);
            for k = 1:3
                s.charge{k} = extract(v.charge{k});
                s.discharge{k} = extract(v.discharge{k});
                compact_e = extract(v.energy{k});
                s.energy{k} = p.duration(k)*compact_e(recovery.state_output,:);
            end
            s.q = extract(v.q);
            s.flex = extract(v.flex);
            s.total_pair = reshape(recovery.fixed_map*s.q,T,K)+s.flex;
            s.ac_pair = s.total_pair;
            has_dc = recovery.Cdc(recovery.pair_index) > 0;
            s.ac_pair(:,has_dc) = 0;
            s.ac_pair(:,recovery.overlap) = extract(v.ac_split);
            s.dc_pair = s.total_pair-s.ac_pair;
            s.net_injection = s.total_pair*recovery.incidence' ...
                +extract(v.ac_split)*recovery.split_incidence';
            s.Q_res = extract(v.rps_deficit);
            s.Cac = recovery.Cac;
            s.Cdc = recovery.Cdc;
            s.Pac = zeros(B,B*T);
            s.Pdc = zeros(B,B*T);
            s.Qannual = zeros(B);
            s.Qannual(recovery.pair_index) = recovery.H*s.q;
            for k = 1:K
                columns = (recovery.receiver(k)-1)*T+(1:T);
                s.Pac(recovery.sender(k),columns) = s.ac_pair(:,k)';
                s.Pdc(recovery.sender(k),columns) = s.dc_pair(:,k)';
            end
            s.objective = dot(recovery.original_obj,x)+recovery.constant_cost;
            function a = extract(ids)
                a = zeros(size(ids));
                keep = ids > 0;
                a(keep) = x(ids(keep));
            end
        end

        function problem = problemCode(status)
            switch status
                case 'OPTIMAL'
                    problem = 0;
                case 'INFEASIBLE'
                    problem = 1;
                case 'UNBOUNDED'
                    problem = 2;
                case 'INF_OR_UNBD'
                    problem = 12;
                case {'TIME_LIMIT','ITERATION_LIMIT','WORK_LIMIT','NODE_LIMIT'}
                    problem = 3;
                case 'INTERRUPTED'
                    problem = 16;
                otherwise
                    problem = 4;
            end
        end
    end
end
