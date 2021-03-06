%% Case Data
clc;clear;
tic
casedata='IEEE33bus_modified.m';
run(fullfile(casedata))

%% Generation Shift / Power Transfer Distribution Matrix
maxiter=80;
iter=1;
run(fullfile('gsf_matrix.m'))

%% Estimated Losses
Ploss_est=0;
DF_P_est=ones(nb,1);

Qloss_est=0;
DF_Q_est=ones(nb,1);

E_P_est=zeros(nb,1);
E_P_est_old=zeros(nb,1);

E_Q_est=zeros(nb,1);
E_Q_est_old=zeros(nb,1);

gendispatch=zeros(2*nb,maxiter);
mismatchdispatch=ones(nb,maxiter);
%% Setting up Matrices for the Quadratic Programming Solver

p_cost=zeros(1,nb);
for i=1:nb
    for j=1:length(gendata(:,6))
        if i==gendata(j,1)
            p_cost(i)=gencostdata(j,6); 
        end
    end
end

while iter~=maxiter
Aeq_P=zeros(1,nb);
for i=1:nb
    for j=1:length(gendata(:,1))
        if i==gendata(j,1)
            Aeq_P(i)=DF_P_est(i);
        end
    end
end

Aeq_Q=zeros(1,nb);
for i=1:nb
    for j=1:length(gendata(:,1))
        if i==gendata(j,1)
            Aeq_Q(i)=DF_Q_est(i);
        end
    end
end

% Demand P & Q

charging_injection=ones(1,nb)*diag(BD).*baseMVA;

p_demand=ones(1,nb)*(busdata(:,3).*DF_P_est)-Ploss_est;
q_demand=ones(1,nb)*(busdata(:,4).*DF_Q_est)-charging_injection-Qloss_est;
%% Setting up Matrices for GSF Formulation
A1=GSF_PP;
A2=GSF_PQ;
pd=busdata(:,3);
qd=busdata(:,4)-diag(BD).*baseMVA;


b1=prat(1:length(branchdata(:,1)))+GSF_PP*(pd+E_P_est)+GSF_PQ*(qd+E_Q_est);
b2=prat(1:length(branchdata(:,1)))-GSF_PP*(pd+E_P_est)-GSF_PQ*(qd+E_Q_est);

A_P=[A1; -A1];
A_Q=[A2; -A2];
b=[b1;b2];

%% Voltage formulation
% Active power voltage coupling
A_Voltage_P=(X(nb+1:end,1:nb))./baseMVA;

AP_Voltage=[A_Voltage_P; -A_Voltage_P];

% Reactive power voltage coupling
A_Voltage_Q=(X(nb+1:end,nb+1:end))./baseMVA;

AQ_Voltage=[A_Voltage_Q; -A_Voltage_Q];

%Voltage constraints
B_Voltage_max=(vmax-vbase)+(X(nb+1:end,1:nb)*(pd+E_P_est)+X(nb+1:end,nb+1:end)*(qd+E_Q_est))./baseMVA;

B_Voltage_min=-((vmin-vbase)+(X(nb+1:end,1:nb)*(pd+E_P_est)+X(nb+1:end,nb+1:end)*(qd+E_Q_est))./baseMVA);

B_Voltage=[B_Voltage_max; B_Voltage_min];


%% Generation limit for each generator
p_lb=zeros(1,nb);
p_ub=zeros(1,nb);
q_lb=zeros(1,nb);
q_ub=zeros(1,nb);
for i=1:nb
    for j=1:length(gendata(:,6))
        if i==gendata(j,1)
            p_lb(i)=gendata(j,10);
            p_ub(i)=gendata(j,9);
            q_lb(i)=gendata(j,5);
            q_ub(i)=gendata(j,4);
        end
    end
end

%% Quadratic cost functions for each generator
Qmatrix=zeros(2*size(A_P,2),2*size(2*A_P,2));
for i=1:nb
    for k=1:length(gencostdata(:,5))
        if gencostdata(k,1)~=0
            if gendata(k,1)==i
                Qmatrix(i,i)=0*gencostdata(k,5);
            end
        end
    end
end

for i=1:nb
    for k=1:length(gencostdata(:,5))
        if gencostdata(k,1)~=0
            if gendata(k,1)==i
                Qmatrix(nb+i,nb+i)=gencostdata(k,5);
            end
        end
    end
end


%% Quadratic Programming with Gurobi Solver
params.numericfocus=3;
names={num2str(zeros(1,2*nb))};
for i=1:nb
names(i) = {num2str("P"+num2str(i))};
end
for k=nb+1:2*nb
    names(k) = {num2str("Q"+num2str(k-nb))};
end
model.varnames = names;
model.obj = [p_cost zeros(1,length(p_cost))];
model.Q = sparse(Qmatrix);
model.A = [sparse(A_P) sparse(A_Q); sparse(AP_Voltage) sparse(AQ_Voltage); sparse(Aeq_P) sparse(zeros(1,size(Aeq_P,2))); sparse(zeros(1,size(Aeq_P,2))) sparse(Aeq_P)];
model.sense = [repmat('<',size(A_P,1),1); repmat('<',size(AP_Voltage,1),1); repmat('=',size(Aeq_P,1),1); repmat('=',size(Aeq_P,1),1)];
model.rhs = full([b(:); B_Voltage(:); p_demand(:); q_demand(:)]);
model.lb = [p_lb, q_lb];
model.ub = [p_ub, q_ub];

gurobi_write(model, 'DCOPF_QP_Q.lp');

results = gurobi(model,params);

%% Lagrange multipliers

lambda.lower = max(0,results.rc);
lambda.upper = -min(0,results.rc);
lambda.ineqlin = -results.pi(1:size(A_P,1));
lambda.ineqlin_voltage= -results.pi(size(A_P,1)+1:end-2);
lambda.eqlin = -results.pi(end-1:end);


%% Generation Cost, Congestion Cost and LMP for each bus
generationcost=-lambda.eqlin;
p_congestioncost=(lambda.ineqlin'*[-GSF_PP ; GSF_PP])';
q_congestioncost=(lambda.ineqlin'*[-GSF_PQ ; GSF_PQ])';
p_lmp=generationcost(1)+p_congestioncost;
q_lmp=generationcost(2)+q_congestioncost;
if iter~=1
P_losscost=lambda.eqlin(1)*(DF_P_est-1);
p_lmp=p_lmp+P_losscost;
Q_losscost=lambda.eqlin(2)*(DF_Q_est-1);
q_lmp=q_lmp+Q_losscost;
end

%% Saving the generation dispatch results at each iteration
for i=iter:iter
gendispatch(:,i)=results.x;
end
if iter~=1
mismatchdispatch=(gendispatch(1:nb,iter-1)-gendispatch(1:nb,iter)).^2+(gendispatch(nb+1:end,iter-1)-gendispatch(nb+1:end,iter)).^2;
end

%% Net injections
pn=results.x(1:nb)-pd-E_P_est;
qn=results.x(nb+1:end)-qd-E_Q_est;

%% Damping parameter (necessary for >100 busses)
w=0.0;
if iter>1
pn_old=gendispatch(1:nb,iter-1)-pd-E_P_est_old;
pn=w*pn_old+(1-w)*pn;

qn_old=gendispatch(nb+1:end,iter-1)-qd-E_Q_est_old;
qn=w*qn_old+(1-w)*qn;
end


%% Lineflow based on GSF_PP and net injections
%% Lineflow based on GSF_PP and net injections

P_lineflow=GSF_PP*pn;
PQ_lineflow=GSF_PQ*qn;
Q_lineflow=GSF_QQ*qn;
QP_lineflow=GSF_QP*pn;

if iter>1
    P_lineflow_old=GSF_PP*pn_old;
    P_lineflow=w*P_lineflow_old+(1-w)*P_lineflow;
    
    PQ_lineflow_old=GSF_PQ*qn_old;
    PQ_lineflow=w*PQ_lineflow_old+(1-w)*PQ_lineflow;
end


ldispatch=[results.x(1:nb), results.x(nb+1:end)];
lineflow=[P_lineflow+PQ_lineflow, Q_lineflow+QP_lineflow];

%% Loss formulation
run(fullfile('lossfactor_Q.m'));

%% Voltage at each bus
Voltageatbus=vbase+((X(nb+1:end,1:nb)*pn)+(X(nb+1:end,nb+1:end)*qn))./baseMVA;


%% Lambda multiplier for voltage constraints
P_Voltagecostmax=(lambda.ineqlin_voltage(1:nb)'*X(nb+1:end,1:nb))';
P_Voltagecostmin=(lambda.ineqlin_voltage(nb+1:end)'*X(nb+1:end,1:nb))';

Q_Voltagecostmax=(lambda.ineqlin_voltage(1:nb)'*X(nb+1:end,nb+1:end))';
Q_Voltagecostmin=(lambda.ineqlin_voltage(nb+1:end)'*X(nb+1:end,nb+1:end))';

%% Criterion to stop further iterations
if any(abs(mismatchdispatch) > 1e-12)
    iter=iter+1;
else
    iter=maxiter;
end
end

toc