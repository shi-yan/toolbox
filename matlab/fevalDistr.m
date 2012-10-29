function [out,res] = fevalDistr( funNm, jobs, varargin )
% Wrapper for embarrassingly parallel function evaluation.
%
% Runs "r=feval(funNm,jobs{i}{:})" for each job in a parallel manner. jobs
% should be a cell array of length nJob and each job should be a cell array
% of parameters to pass to funNm. funNm must be a function in the path and
% must return a single value (which may be a dummy value if funNm writes
% results to disk). Different forms of parallelization are supported
% depending on the hardware and Matlab toolboxes available. The type of
% parallelization is determined by the parameter 'type' described below.
%
% type='LOCAL': jobs are executed using a simple "for" loop. This implies
% no parallelization and is the default fallback option.
%
% type='PARFOR': jobs are executed using a "parfor" loop. This option is
% only available if the Matlab *Parallel Computing Toolbox* is installed.
% Make sure to setup Matlab workers first using "matlabpool open".
%
% type='DISTR': jobs are executed on the Caltech cluster. Distributed
% queuing system must be installed separately. Currently this option is
% only supported on the Caltech cluster but could easily be installed on
% any Linux cluster as it requires only SSH and a shared filesystem.
% Parameter pLaunch is used for controller('launchQueue',pLaunch{:}) and
% determines cluster machines used (e.g. pLaunch={48,401:408}).
%
% type='COMPILED': jobs are executed locally in parallel by first compiling
% an executable and then running it in background. This option requires the
% *Matlab Compiler* to be installed (but does NOT require the Parallel
% Computing Toolbox). Compiling can take 1-10 minutes, so use this option
% only for large jobs. (On Linux alter startup.m by calling addpath() only
% if ~isdeployed, otherwise will get error about "CTF" after compiling).
% Note that relative paths will not work after compiling so all paths used
% by funNm must be absolute paths.
%
% type='WINHPC': jobs are executed on a Windows HPC Server 2008 cluster.
% Similar to type='COMPILED', except after compiling, the executable is
% queued to the HPC cluster where all computation occurs. This option
% likewise requires the *Matlab Compiler*. Paths to data, etc., must be
% absolute paths and available from HPC cluster. Parameter pLaunch should
% have two fields 'scheduler' and 'shareDir' that define the HPC Server.
% For example, at MSR one possible cluster is defined by scheduler =
% 'MSR-L25-DEV21' and shareDir = '\\msr-arrays\scratch\msr-pool\L25-dev21'.
% Note call to 'job submit' from Matlab will hang unless pwd is saved
% (simply call 'job submit' from cmd prompt and enter pwd).
%
% USAGE
%  [out,res] = fevalDistr( funNm, jobs, [varargin] )
%
% INPUTS
%  funNm      - name of function that will process jobs
%  jobs       - [1xnJob] cell array of parameters for each job
%  varargin   - additional params (struct or name/value pairs)
%   .type       - ['local'], 'parfor', 'distr', 'compiled', 'winhpc'
%   .pLaunch    - [] extra params for type='distr' or type='winhpc'
%   .group      - [1] send jobs in batches (only relevant if type='distr')
%
% OUTPUTS
%  out        - 1 if jobs completed successfully
%  res        - [1xnJob] cell array containing results of each job
%
% EXAMPLE
%  % Note: in this case parallel versions are slower since conv2 is so fast
%  n=16; jobs=cell(1,n); for i=1:n, jobs{i}={rand(500),ones(25)}; end
%  tic, [out,J1] = fevalDistr('conv2',jobs,'type','local'); toc,
%  tic, [out,J2] = fevalDistr('conv2',jobs,'type','parfor'); toc,
%  tic, [out,J3] = fevalDistr('conv2',jobs,'type','compiled'); toc
%  [isequal(J1,J2), isequal(J1,J3)], figure(1); montage2(cell2array(J1))
%
% See also matlabpool mcc
%
% Piotr's Image&Video Toolbox      Version NEW
% Copyright 2012 Piotr Dollar.  [pdollar-at-caltech.edu]
% Please email me if you find bugs, or have suggestions or questions!
% Licensed under the Simplified BSD License [see external/bsd.txt]
dfs={'type','local','pLaunch',[],'group',1};
[type,pLaunch,group]=getPrmDflt(varargin,dfs,1); store=(nargout==2);
if(isempty(jobs)), res=cell(1,0); out=1; return; end
switch lower(type)
  case 'local',     [out,res]=fedLocal(funNm,jobs,store);
  case 'parfor',    [out,res]=fedParfor(funNm,jobs,store);
  case 'distr',     [out,res]=fedDistr(funNm,jobs,pLaunch,group,store);
  case 'compiled',  [out,res]=fedCompiled(funNm,jobs,store);
  case 'winhpc',    [out,res]=fedWinhpc(funNm,jobs,pLaunch,store);
  otherwise,        error('unkown type: ''%s''',type);
end
end

function [out,res] = fedLocal( funNm, jobs, store )
% Run jobs locally using for loop.
nJob=length(jobs); res=cell(1,nJob); out=1;
tid=ticStatus('collecting jobs');
for i=1:nJob, r=feval(funNm,jobs{i}{:});
  if(store), res{i}=r; end; tocStatus(tid,i/nJob); end
end

function [out,res] = fedParfor( funNm, jobs, store )
% Run jobs locally using parfor loop.
nJob=length(jobs); res=cell(1,nJob); out=1;
parfor i=1:nJob, r=feval(funNm,jobs{i}{:});
  if(store), res{i}=r; end; end
end

function [out,res] = fedDistr( funNm, jobs, pLaunch, group, store )
% Run jobs using Linux queuing system.
if(~exist('controller.m','file'))
  msg='distributed queuing not installed, switching to type=''local''.';
  warning(msg); [out,res]=fedLocal(funNm,jobs,store); return; %#ok<WNTAG>
end
nJob=length(jobs); res=cell(1,nJob); controller('launchQueue',pLaunch{:});
if( group>1 )
  nJobGrp=ceil(nJob/group); jobsGrp=cell(1,nJobGrp); k=0;
  for i=1:nJobGrp, k1=min(nJob,k+group);
    jobsGrp{i}={funNm,jobs(k+1:k1),'type','local'}; k=k1; end
  nJob=nJobGrp; jobs=jobsGrp; funNm='fevalDistr';
end
jids=controller('jobsAdd',nJob,funNm,jobs); k=0;
fprintf('Sent %i jobs...\n',nJob); tid=ticStatus('collecting jobs');
while( 1 )
  jids1=controller('jobProbe',jids);
  if(isempty(jids1)), pause(.1); continue; end
  jid=jids1(1); [r,err]=controller('jobRecv',jid);
  if(~isempty(err)), disp('ABORTING'); out=0; break; end
  k=k+1; if(store), res{jid==jids}=r; end
  tocStatus(tid,k/nJob); if(k==nJob), out=1; break; end
end; controller('closeQueue');
end

function [out,res] = fedCompiled( funNm, jobs, store )
% Run jobs locally in background in parallel using compiled code.
nJob=length(jobs); res=cell(1,nJob); tDir=jobSetup('.',funNm,'' );
cmd=[tDir 'fevalDistrDisk ' funNm ' ' tDir ' ']; i=0; k=0;
Q=feature('numCores'); q=0; tid=ticStatus('collecting jobs');
while( 1 )
  % launch jobs until queue is full (q==Q) or all jobs launched (i==nJob)
  while(q<Q && i<nJob), q=q+1; i=i+1; jobSave(tDir,jobs{i},i);
    if(ispc), system2(['start /B /min ' cmd int2str2(i,10)],0);
    else system2([cmd int2str2(i,10) ' &'],0); end
  end
  % collect completed jobs (k1 of them), release queue slots
  done=jobFileIds(tDir,'done'); k1=length(done); k=k+k1; q=q-k1;
  for i1=done, res{i1}=jobLoad(tDir,i1,store); end
  pause(1); tocStatus(tid,k/nJob); if(k==nJob), out=1; break; end
end
for i=1:10, try rmdir(tDir,'s'); break; catch,pause(1),end; end %#ok<CTCH>
end

function [out,res] = fedWinhpc( funNm, jobs, pLaunch, store )
% Run jobs using Windows HPC Server.
nJob=length(jobs); res=cell(1,nJob);
dfs={'shareDir','REQ','scheduler','REQ','executable','','maxTasks',256};
[shareDir,scheduler,executable,maxTasks]=getPrmDflt(pLaunch,dfs,1);
tDir = jobSetup(shareDir,funNm,executable);
for i=1:nJob, jobSave(tDir,jobs{i},i); end
scheduler=[' /scheduler:' scheduler ' '];
tids=hpcSubmit(tDir,scheduler,funNm,1:nJob,maxTasks); k=0;
ticId=ticStatus('collecting jobs'); check=clock; save([tDir 'state']);
while( 1 )
  done=jobFileIds(tDir,'done'); k=k+length(done);
  for i1=done, res{i1}=jobLoad(tDir,i1,store); end
  if(etime(clock,check)>120)
    save([tDir 'state' num2str(now) '.mat']); tids0=tids;
    stalled=hpcFindStalled(tDir,tids,scheduler); check=clock;
    tids(stalled)=hpcSubmit(tDir,scheduler,funNm,stalled,maxTasks);
    for i=stalled, system2(['task cancel ' tids0{i} scheduler],0); end
  end
  pause(1); tocStatus(ticId,k/nJob); if(k==nJob), out=1; break; end
end
for i=1:10, try rmdir(tDir,'s'); break; catch,pause(1),end; end %#ok<CTCH>
end

function stalled = hpcFindStalled( tDir, tids, scheduler )
% Helper: look for and exclude bad nodes in hpc cluster (can be expensive).
ids=setdiff(jobFileIds(tDir,'in'),jobFileIds(tDir,'started'));
stalled=zeros(1,length(tids));
for id=ids, m=system2(['task view ' tids{id} scheduler],0);
  a=strcmpi(hpcParse(m,'State',0),'running');
  u=hpcParse(m,'Total User Time',2); e=hpcParse(m,'Elapsed Time',2);
  stalled(id)=a && u/e<.01 && e>120;
end
stalled=find(stalled); n=length(stalled); w=repmat(' ',1,80);
fprintf('\nDiscovered %i stalled jobs.\n%s\n',n,w);
end

function tids = hpcSubmit( tDir, scheduler, funNm, ids, maxTasks )
% Helper: send jobs w given ids to HPC cluster.
n=length(ids); tids=cell(1,n); if(n==0), return; end; k=ceil(n/maxTasks);
if(k>1), b=round(linspace(1,n+1,k+1));
  for i=1:k, is=b(i):b(i+1)-1;
    tids(is)=hpcSubmit(tDir,scheduler,funNm,ids(is),maxTasks);
  end; return;
end
m=system2(['cluscfg view' scheduler],0);
nCores=hpcParse(m,'total number of cores',1)-8;
nCores=['/numcores:' int2str(min([1024 nCores length(ids)])) '-*'];
m=system2(['job new  ' nCores scheduler],1);
jid=hpcParse(m,'created job, id',0);
cmd0=['job add ' jid scheduler '/workdir:' tDir ' '];
cmd1=[' fevalDistrDisk ' funNm ' ' tDir ' '];
s=min(ids); e=max(ids); p=n>1 && isequal(ids,s:e);
if(p), jid1=[jid '.1']; else jid1=jid; end
for i=1:n, tids{i}=[jid1 '.' int2str(i)]; end
if(p), system2([cmd0 '/parametric:' int2str(s) '-' int2str(e) cmd1 '*'],1);
else for id=ids, system2([cmd0 cmd1 int2str(id)],0); end; end
system2(['job submit /id:' jid scheduler],1); disp(repmat(' ',1,80));
end

function v = hpcParse( msg, key, tonum )
% Helper: extract val corresponding to key in hpc msg.
t=regexp(msg,': |\n','split'); t=strtrim(t(1:floor(length(t)/2)*2));
keys=t(1:2:end); vals=t(2:2:end); j=find(strcmpi(key,keys));
if(isempty(j)), error('key ''%s'' not found in:\n %s',key,msg); end
v=vals{j}; if(tonum==0), return; elseif(isempty(v)), v=0; return; end
if(tonum==1), v=str2double(v); return; end
v=regexp(v,' ','split'); v=str2double(regexp(v{1},':','split'));
if(numel(v)==4), v(5)=0; end; v=((v(1)*24+v(2))*60+v(3))*60+v(4)+v(5)/1000;
end

function tDir = jobSetup( rtDir, funNm, executable )
%  Helper: prepare by setting up temporary dir and compiling funNm
t=clock; t=mod(t(end),1); t=round((t+rand)/2*1e15);
tDir=[rtDir filesep sprintf('fevalDistr-%015i',t) filesep]; mkdir(tDir);
if(~isempty(executable) && exist(executable,'file'))
  fprintf('Reusing compiled executable...\n'); copyfile(executable,tDir);
else
  fprintf('Compiling (this may take a while)...\n');
  mcc('-m','fevalDistrDisk','-d',tDir,'-a',funNm);
  if(~isempty(executable)), [~,~,e]=fileparts(executable);
    copyfile([tDir filesep 'fevalDistrDisk' e],executable); end
end
end

function ids = jobFileIds( tDir, type )
% Helper: get list of job files ids on disk of given type.
fs=dir([tDir '*-' type '*']); fs={fs.name}; n=length(fs);
ids=zeros(1,n); for i=1:n, ids(i)=str2double(fs{i}(1:10)); end
end

function jobSave( tDir, job, ind ) %#ok<INUSL>
% Helper: save job to temporary file for use with fevalDistrDisk()
save([tDir int2str2(ind,10) '-in'],'job');
end

function r = jobLoad( tDir, ind, store )
% Helper: load job and delete temporary files from fevalDistrDisk()
f=[tDir int2str2(ind,10)];
if(store), r=load([f '-out']); r=r.r; else r=[]; end
fs={[f '-done'],[f '-in.mat'],[f '-out.mat'],[f '-started']};
delete(fs{:}); pause(.1);
for i=1:4, k=0; while(exist(fs{i},'file')==2) %#ok<ALIGN>
    warning('Waiting to delete %s.',fs{i}); %#ok<WNTAG>
    delete(fs{i}); pause(5); k=k+1; if(k>12), break; end;
  end; end
end

function msg = system2( cmd, show )
% Helper: wraps system() call
if(show), disp(cmd); end
[status,msg]=system(cmd); msg=msg(1:end-1);
if(status), error(msg); end
if(show), disp(msg); end
end
