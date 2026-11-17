Supporting material for Zhang et al., "Unlocking the climate benefits of renewables through flexible power exchange."

## Overview

This repository contains MATLAB code for electricity system planning and the typical-day data used as model inputs for 2025, 2030 and 2035. The model compares scenarios with different rules for interprovincial electricity exchange. A complete model run requires Gurobi and additional input workbooks.

## MATLAB Code Files

The MATLAB files set up the planning scenarios, formulate and solve the models, and summarize the results.

1. The file `Main_function.m` starts the default sequence of planning stages. The file `run_simulation.m` schedules the stages and passes capacity and investment records from one stage to the next.
2. The nine `run_<period>_<scenario>.m` scripts select a single planning stage. The period labels `24to25`, `25to30` and `30to35` correspond to the 2025, 2030 and 2035 target years. The `S25_75` scripts select scenarios S25, S50 and S75 for the corresponding stage.
3. The file `model_24to25_CPD.m` formulates the common 2025 baseline.
4. The files `model_25to30_CPD.m` and `model_30to35_CPD.m` formulate the 2030 and 2035 stages with prescribed annual interprovincial exchanges.
5. The files `model_25to30_MCD.m` and `model_30to35_MCD.m` formulate the 2030 and 2035 stages with fixed contract profiles.
6. The files `model_25to30_SMCD.m` and `model_30to35_SMCD.m` formulate the 2030 and 2035 stages with flexible hourly interprovincial dispatch.
7. The files `model_25to30_S25_75.m` and `model_30to35_S25_75.m` formulate the 2030 and 2035 stages with flexible shares of 25%, 50% or 75% of annual contract energy.
8. The file `CompactPlanningSupport.m` builds the sparse linear program, calls Gurobi and recovers the model variables from the solution.
9. The file `SimulationSupport.m` defines scenario settings and prepares the input workbooks for each stage.
10. The file `TimeSupport.m` reads the time index and week weights and constructs contract profiles from receiving provinces' daily load. The file `AnnualLoadSupport.m` calculates weighted annual load.
11. The file `ExchangeSupport.m` converts annual interprovincial and international exchange inputs into hourly power profiles.
12. The file `InvestmentSupport.m` tracks capacity additions and annualized investment costs over asset lifetimes.
13. The file `StorageSupport.m` summarizes storage energy states and annual charging and discharging.

## CSV Data Files

The folders `Data/2025/`, `Data/2030/` and `Data/2035/` each contain seven CSV files extracted from the model run inputs. Scenarios for the same target year share the same typical-day data.

1. The file `load.csv` contains hourly electricity demand in MW before applying scenario load multipliers.
2. The file `cf_wind.csv` contains hourly wind capacity factors.
3. The file `cf_pv.csv` contains hourly solar PV capacity factors.
4. The file `hydro.csv` contains hourly hydropower output limits in MW.
5. The file `nuclear.csv` contains fixed nuclear output in MW for each province, applied to every sampled hour.
6. The file `time_weights.csv` lists the four typical weeks, their source-hour ranges and their repetition weights.
7. The file `time_index.csv` maps each sample hour to its typical week, day, hour and source-hour index.

The four hourly profiles contain 31 province rows in source order and 672 hourly columns. The model uses 30 of these rows after excluding Tibet. The sample comprises 28 days grouped into four continuous 168-hour weeks. Columns `Hour_001` through `Hour_672` correspond to `MatrixRow` 1 through 672 in `time_index.csv`. To obtain annual energy in MWh, multiply each hourly MW value by one hour and its week weight, then sum across sample hours. The weights represent 8,760 hours in each target year.
