%% Case Data
clear;
tic
casedata='IEEE33bus.m';
run(fullfile(casedata))

%% Loadcurve

loadprofiledata=readtable('202002110000.xlsx', 'PreserveVariableNames', true, 'Range', 'C8:C103', 'ReadVariableNames', true);
loadcurve=table2array(loadprofiledata(:,1));
loadcurve=str2double(loadcurve);
loadcurve_base=loadcurve./mean(loadcurve);

%% Generation Shift / Power Transfer Distribution Matrix

run(fullfile('ptdf_matrix.m'))

%% Iteration Setup

step=0.25;
iter=1;
maxiter=100;
minute=0;

%% Generator Bus Connection Matrix

Ag=zeros(nb,ng);
for i=1:nb
    for j=1:ng
        if gendata(j,1)==i
            Ag(i,j)=1;
        end
    end
end

%% Loadcurve timesteps

while step<24
run(fullfile(casedata))
busdata(:,3)=busdata(:,3)*loadcurve_base(step*4);
iter=1;
   

%% Estimated Losses
Ploss_est=0;
LF_est=zeros(nb,1);
DF_est=ones(nb,1);
E_est=zeros(nb,1);
E_est_old=zeros(nb,1);
gendispatch=zeros(ng,maxiter);
mismatchdispatch=ones(ng,maxiter);

%% Setting up Matrices for the Quadratic Programming Solver
% Cost function to minimize
f=gencostdata(:,6)';

%% Iteration for the loss formulation starts here

while iter~=maxiter

% Assigning the delivery factors to the generation units
Aeq=ones(1,ng);
for i=1:nb
   for j=1:ng
        if gendata(j,1)==i
            Aeq(j)=DF_est(i);
        end
    end
end

% Demand Side of Pg=Pd Equation with Delivery Factor
beq=ones(1,nb)*(busdata(:,3).*DF_est);
%Demand Side of Pg=Pd Equation + Losses
beq=beq-Ploss_est;                                      


%% Setting up Matrices for PTDF Formulation
A1=PTDF*Ag;    
pd=busdata(:,3);

b1=prat(1:length(branchdata(:,1)))+PTDF*(pd+E_est);
b2=prat(1:length(branchdata(:,1)))-PTDF*(pd+E_est);

A=[A1; -A1];
b=[b1;b2];


%% Generation limit for each generator
lb=gendata(:,10);
ub=gendata(:,9);


%% Quadratic cost functions for each generator
Qmatrix=zeros(size(A,2),size(A,2));
for i=1:length(gencostdata(:,5))
    if gencostdata(i,5)~=0
        Qmatrix(i,i)=gencostdata(i,5);
    end
end

%% Quadratic Programming with Gurobi Solver
names={num2str(zeros(1,length(gendata(:,1))))};
for i=1:length(gendata(:,1))
names(i) = {num2str("P"+num2str(i))};
end
model.varnames = names;
model.obj = f; 
model.Q = sparse(Qmatrix);
model.A = [sparse(A); sparse(Aeq)]; % A must be sparse
model.sense = [repmat('<',size(A,1),1); repmat('=',size(Aeq,1),1)];
model.rhs = full([b(:); beq(:)]); % rhs must be dense
if ~isempty(lb)
    model.lb = lb;
else
    model.lb = -inf(size(model.A,2),1); % default lb for MATLAB is -inf
end
if ~isempty(ub)
    model.ub = ub;
else
    model.ub= inf(size(model.A,2),1);
end

gurobi_write(model, 'DCOPF_QP.lp');

results = gurobi(model);

%% Lagrange multipliers

lambda.lower = max(0,results.rc);
lambda.upper = -min(0,results.rc);
lambda.ineqlin = -results.pi(1:size(A,1));
lambda.eqlin = results.pi((size(A,1)+1):end);


%% Generation Cost, Congestion Cost and LMP for each bus
generationcost=lambda.eqlin;
congestioncost=(lambda.ineqlin'*[-PTDF ; PTDF])';
lmp=generationcost+congestioncost;

%% Saving the generation dispatch results at each iteration
for i=iter:iter
gendispatch(:,i)=results.x;
end
if iter~=1
mismatchdispatch=(gendispatch(:,iter-1)-gendispatch(:,iter)).^2;
end

%% Net injections
pn=Ag*results.x-pd-E_est;

%% Damping parameter (necessary for >100 busses)
w=0.87;
if iter>1
pn_old=Ag*gendispatch(:,iter-1)-pd-E_est_old;
pn=w*pn_old+(1-w)*pn;
end

%% Lineflow based on PTDF and net injections
lineflow=PTDF*pn;
if iter>1
lineflow_old=PTDF*pn_old;
lineflow=w*lineflow_old+(1-w)*lineflow;
end

%% Loss formulation
run(fullfile('lossfactor.m'));

%% Checking at which iteration the loss formulation converges
checkiter=iter;

%% Adding loss costs to LMPs
if iter~=1
losscost=lambda.eqlin*(DF_est-1);
lmp=lmp+losscost;
end

%% Criterion to stop further iterations
if any(abs(mismatchdispatch) > 1e-8)
    iter=iter+1;
else
    iter=maxiter;
end

end


%% Printing out the solutions

if iter==maxiter || iter==2
%Printing out the Solution
for v=1:length(names)
fprintf('\n %s = %2.2f MW\n', names{v}, results.x(v));
end

for v=1:length(generationcost)
fprintf('\n Generation cost = %g $/MWh\n\n', generationcost);
end

busnumber=busdata(:,1);

for v=1:length(congestioncost)
    if congestioncost(v)~=0
    fprintf(' Congestion Cost @ Bus %g = %4.2f $/MWh\n', busnumber(v) , congestioncost(v));
    end
end

fprintf('\n\n   LMP -- Bus Number ||    Generation Cost ||  Congestion Cost \n \n')
for v=1:length(lmp)
        if lmp(v)~=0
         fprintf(' The LMP @ Bus %2.4g is %4.2f $/MWh generation cost and %4.2f $/MWh congestion cost\n', busnumber(v) , generationcost, congestioncost(v));
        end
end


fprintf('\n              Line flow Table \n')
fprintf('   From Bus  ||    To Bus   ||   Line Flow \n\n')
for v=1:length(lineflow)
        fprintf('%8.0f     ||%8.0f     ||%13.6f MW  \n', fb(v) , tb(v) , lineflow(v));
end

fprintf('\n The objective value is %4.2f $/h\n', results.objval);
end

%% Saving the results in .mat files
if ~exist(fullfile('loadprofile', casedata), 'dir')
       mkdir('loadprofile', casedata)
end
f1=num2str(minute*60);
f5=num2str((minute+0.25)*60);
f2='load at timestep - hour';
f3=num2str(floor(step-0.25));
f4='- minute -';
filename=strcat(f2,f3,f4,f1,f4,f5);
f=fullfile('loadprofile', casedata , filename);
save(f);

%% Step increase for 24 hour loadflow analysis
minute=minute+0.25;
if minute > 0.75
    minute=0;
end
step=step+0.25;
end
toc