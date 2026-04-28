function MATLABRocketSimuApp()
% MATLABRocketSimuApp
% GUI rocket simulation app that:
% 1) Parses OpenRocket .ork XML
% 2) Requests missing parameters from user
% 3) Runs Monte Carlo simulations
% 4) Plots 3D trajectory, stability before/after recovery, CP/CG vs time
% 5) Reports apogee statistics
%
% Designed for files in this repository, especially:
%   rocket.ork, roc3ket.ork, output/parameters.json,
%   output/thrust_source.csv, output/drag_curve.csv

    repoRoot = fileparts(fileparts(mfilename('fullpath')));

    app = struct();
    app.fig = uifigure('Name','MATLAB RocketSimu (ORK + Monte Carlo)', ...
        'Position',[80 80 1400 860]);

    app.grid = uigridlayout(app.fig,[8 6]);
    app.grid.RowHeight = {36,36,36,'1x','1x','1x',40,40};
    app.grid.ColumnWidth = {180,180,180,'1x','1x','1x'};
    app.grid.Padding = [10 10 10 10];

    app.lblFile = uilabel(app.grid,'Text','ORK File:');
    app.lblFile.Layout.Row = 1; app.lblFile.Layout.Column = 1;

    app.editFile = uieditfield(app.grid,'text');
    app.editFile.Value = fullfile(repoRoot,'rocket.ork');
    app.editFile.Layout.Row = 1; app.editFile.Layout.Column = [2 5];

    app.btnBrowse = uibutton(app.grid,'push','Text','Browse ORK', ...
        'ButtonPushedFcn',@(src,evt)onBrowse());
    app.btnBrowse.Layout.Row = 1; app.btnBrowse.Layout.Column = 6;

    app.lblIter = uilabel(app.grid,'Text','Monte Carlo Iterations:');
    app.lblIter.Layout.Row = 2; app.lblIter.Layout.Column = 1;

    app.editIter = uieditfield(app.grid,'numeric');
    app.editIter.Limits = [1 Inf];
    app.editIter.RoundFractionalValues = true;
    app.editIter.Value = 200;
    app.editIter.Layout.Row = 2; app.editIter.Layout.Column = 2;

    app.lblSeed = uilabel(app.grid,'Text','Random Seed:');
    app.lblSeed.Layout.Row = 2; app.lblSeed.Layout.Column = 3;

    app.editSeed = uieditfield(app.grid,'numeric');
    app.editSeed.Value = 42;
    app.editSeed.Layout.Row = 2; app.editSeed.Layout.Column = 4;

    app.chkParallel = uicheckbox(app.grid,'Text','Use Parallel Pool (if available)');
    app.chkParallel.Value = false;
    app.chkParallel.Layout.Row = 2; app.chkParallel.Layout.Column = [5 6];

    app.btnRun = uibutton(app.grid,'push','Text','Run Monte Carlo', ...
        'ButtonPushedFcn',@(src,evt)onRun());
    app.btnRun.Layout.Row = 3; app.btnRun.Layout.Column = 1;

    app.btnLoadDefaults = uibutton(app.grid,'push','Text','Load Repo Defaults', ...
        'ButtonPushedFcn',@(src,evt)onLoadDefaults());
    app.btnLoadDefaults.Layout.Row = 3; app.btnLoadDefaults.Layout.Column = 2;

    app.lblApogee = uilabel(app.grid,'Text','Apogee: --');
    app.lblApogee.FontWeight = 'bold';
    app.lblApogee.Layout.Row = 3; app.lblApogee.Layout.Column = [3 6];

    app.axTraj = uiaxes(app.grid);
    app.axTraj.Layout.Row = [4 5]; app.axTraj.Layout.Column = [1 3];
    title(app.axTraj,'3D Trajectory'); grid(app.axTraj,'on'); view(app.axTraj,3);
    xlabel(app.axTraj,'X (m)'); ylabel(app.axTraj,'Y (m)'); zlabel(app.axTraj,'Altitude (m)');

    app.axStability = uiaxes(app.grid);
    app.axStability.Layout.Row = [4 5]; app.axStability.Layout.Column = [4 6];
    title(app.axStability,'Stability Margin: Pre/Post Recovery');
    xlabel(app.axStability,'Time (s)'); ylabel(app.axStability,'Stability Margin (cal)');
    grid(app.axStability,'on');

    app.axCpCg = uiaxes(app.grid);
    app.axCpCg.Layout.Row = 6; app.axCpCg.Layout.Column = [1 3];
    title(app.axCpCg,'CP and CG vs Time');
    xlabel(app.axCpCg,'Time (s)'); ylabel(app.axCpCg,'Axial Position from Nose (m)');
    grid(app.axCpCg,'on');

    app.axHist = uiaxes(app.grid);
    app.axHist.Layout.Row = 6; app.axHist.Layout.Column = [4 6];
    title(app.axHist,'Monte Carlo Apogee Histogram');
    xlabel(app.axHist,'Apogee (m)'); ylabel(app.axHist,'Count');
    grid(app.axHist,'on');

    app.txtLog = uitextarea(app.grid);
    app.txtLog.Layout.Row = [7 8]; app.txtLog.Layout.Column = [1 6];
    app.txtLog.Value = {'Ready.'};

    onLoadDefaults();

    function onBrowse()
        [f,p] = uigetfile({'*.ork','OpenRocket file (*.ork)';'*.*','All files'});
        if isequal(f,0), return; end
        app.editFile.Value = fullfile(p,f);
        logMsg(['Selected ORK: ', app.editFile.Value]);
    end

    function onLoadDefaults()
        candidate = fullfile(repoRoot,'rocket.ork');
        if isfile(candidate)
            app.editFile.Value = candidate;
        end
        logMsg('Loaded repository defaults.');
    end

    function onRun()
        try
            rng(app.editSeed.Value);
            orkFile = app.editFile.Value;
            nIter = max(1,round(app.editIter.Value));

            data = loadInputsFromRepo(repoRoot, orkFile);
            data = fillMissingWithPrompt(data);

            if app.chkParallel.Value
                try
                    if isempty(gcp('nocreate')), parpool('threads'); end
                    usePar = true;
                catch
                    usePar = false;
                    logMsg('Parallel pool unavailable. Falling back to serial execution.');
                end
            else
                usePar = false;
            end

            logMsg('Running Monte Carlo simulations...');
            [results, sample] = runMonteCarlo(data, nIter, usePar);
            valid = ~isnan([results.apogee]);
            rValid = results(valid);
            if isempty(rValid)
                error('All simulations failed. Check input values.');
            end

            apogees = [rValid.apogee];
            mu = mean(apogees); sd = std(apogees);
            p05 = prctile(apogees,5); p95 = prctile(apogees,95);

            app.lblApogee.Text = sprintf('Apogee mean=%.2f m | std=%.2f | 5%%=%.2f | 95%%=%.2f | max=%.2f', ...
                mu, sd, p05, p95, max(apogees));

            cla(app.axTraj); cla(app.axStability); cla(app.axCpCg); cla(app.axHist);

            plot3(app.axTraj, sample.xyz(:,1), sample.xyz(:,2), sample.xyz(:,3), 'b-', 'LineWidth',1.5);
            hold(app.axTraj,'on');
            scatter3(app.axTraj, sample.xyz(sample.iApogee,1), sample.xyz(sample.iApogee,2), sample.xyz(sample.iApogee,3), ...
                40,'filled','MarkerFaceColor',[1 0.2 0.2]);
            hold(app.axTraj,'off');
            legend(app.axTraj,{'Trajectory','Apogee'},'Location','best');

            preMask = sample.t <= sample.tRecovery;
            postMask = sample.t > sample.tRecovery;
            plot(app.axStability, sample.t(preMask), sample.stability(preMask), 'Color',[0 0.45 0.74], 'LineWidth',1.4);
            hold(app.axStability,'on');
            plot(app.axStability, sample.t(postMask), sample.stability(postMask), 'Color',[0.85 0.33 0.1], 'LineWidth',1.4);
            xline(app.axStability, sample.tRecovery, '--k', 'Recovery');
            hold(app.axStability,'off');
            legend(app.axStability,{'Before Recovery','After Recovery','Recovery Event'},'Location','best');

            plot(app.axCpCg, sample.t, sample.cp, 'm-', 'LineWidth',1.4);
            hold(app.axCpCg,'on');
            plot(app.axCpCg, sample.t, sample.cg, 'g-', 'LineWidth',1.4);
            xline(app.axCpCg, sample.tRecovery, '--k', 'Recovery');
            hold(app.axCpCg,'off');
            legend(app.axCpCg,{'CP','CG','Recovery Event'},'Location','best');

            histogram(app.axHist, apogees, min(30,max(10,ceil(sqrt(numel(apogees))))));

            logMsg(sprintf('Done. %d/%d valid runs. Mean apogee %.2f m.',numel(rValid),nIter,mu));
        catch ME
            uialert(app.fig, ME.message, 'Simulation Error');
            logMsg(['ERROR: ', ME.message]);
        end
    end

    function logMsg(msg)
        ts = datestr(now,'HH:MM:SS');
        app.txtLog.Value = [app.txtLog.Value; {sprintf('[%s] %s',ts,msg)}];
        drawnow limitrate;
    end
end

function data = loadInputsFromRepo(repoRoot, orkFile)
    data = struct();
    data.repoRoot = repoRoot;
    data.orkFile = orkFile;

    paramsPath = fullfile(repoRoot,'output','parameters.json');
    thrustPath = fullfile(repoRoot,'output','thrust_source.csv');
    dragPath = fullfile(repoRoot,'output','drag_curve.csv');

    if isfile(paramsPath)
        p = jsondecode(fileread(paramsPath));
        data.params = p;
    else
        data.params = struct();
    end

    if ~isfile(orkFile)
        error('ORK file not found: %s', orkFile);
    end

    data.ork = parseOrkXml(orkFile);

    if isfile(thrustPath)
        T = readtable(thrustPath);
        data.thrustTime = T{:,1};
        data.thrustN = T{:,2};
    else
        data.thrustTime = [];
        data.thrustN = [];
    end

    if isfile(dragPath)
        D = readtable(dragPath);
        data.dragMach = D{:,1};
        data.dragCd = D{:,2};
    else
        data.dragMach = [];
        data.dragCd = [];
    end
end

function ork = parseOrkXml(orkPath)
    xDoc = xmlread(orkPath);
    ork = struct();

    getTagNumber = @(tag) readFirstNumeric(xDoc, tag);

    % OpenRocket XML has multiple <length> tags; we use repository JSON as primary
    % source and keep XML length as fallback.
    ork.lengthBody = getTagNumber('length');
    ork.radius = getTagNumber('radius');
    ork.mass = getTagNumber('mass');
    ork.cg = getTagNumber('cg');
    ork.referenceDiameter = 2*ork.radius;

    dep = readFirstText(xDoc,'deployevent');
    delay = readFirstNumeric(xDoc,'deploydelay');
    ork.recoveryEvent = dep;
    ork.recoveryDelay = delay;

    if isnan(ork.recoveryDelay), ork.recoveryDelay = 1.0; end
    if isempty(ork.recoveryEvent), ork.recoveryEvent = 'apogee'; end
end

function data = fillMissingWithPrompt(data)
    p = data.params;

    mass = tryGet(p, {'rocket','mass'}, NaN);
    if isnan(mass), mass = data.ork.mass; end
    if isnan(mass)
        mass = askNumeric('Rocket dry mass (kg):', 0.3);
    end

    radius = tryGet(p, {'rocket','radius'}, NaN);
    if isnan(radius), radius = data.ork.radius; end
    if isnan(radius)
        radius = askNumeric('Rocket outer radius (m):', 0.0215);
    end

    length = tryGet(p, {'rocket','total_length'}, NaN);
    if isnan(length), length = data.ork.lengthBody; end
    if isnan(length)
        length = askNumeric('Rocket total length (m):', 0.55);
    end

    motorDry = tryGet(p, {'motors','dry_mass'}, NaN);
    propMass = tryGet(p, {'motors','propellant_mass'}, NaN);
    burnTime = tryGet(p, {'motors','burn_time'}, NaN);
    if isnan(motorDry), motorDry = askNumeric('Motor dry mass (kg):', 0.05); end
    if isnan(propMass), propMass = askNumeric('Propellant mass (kg):', 0.22); end
    if isnan(burnTime), burnTime = askNumeric('Burn time (s):', 3.2); end

    railLen = tryGet(p, {'flight','rail_length'}, 2.0);
    headingDeg = tryGet(p, {'flight','heading'}, 90.0);
    inclDeg = tryGet(p, {'flight','inclination'}, 90.0);

    windMu = tryGet(p, {'environment','wind_average'}, 2.0);
    windSigma = tryGet(p, {'environment','wind_turbulence'}, 0.14);

    if isempty(data.thrustTime)
        [f,pth] = uigetfile({'*.csv','CSV files'}, 'Select thrust_source.csv');
        if isequal(f,0), error('thrust_source.csv required.'); end
        T = readtable(fullfile(pth,f));
        data.thrustTime = T{:,1}; data.thrustN = T{:,2};
    end
    if isempty(data.dragMach)
        [f,pth] = uigetfile({'*.csv','CSV files'}, 'Select drag_curve.csv');
        if isequal(f,0), error('drag_curve.csv required.'); end
        D = readtable(fullfile(pth,f));
        data.dragMach = D{:,1}; data.dragCd = D{:,2};
    end

    data.model = struct( ...
        'mDry', mass + motorDry, ...
        'mProp', propMass, ...
        'radius', radius, ...
        'areaRef', pi*radius^2, ...
        'length', length, ...
        'burnTime', burnTime, ...
        'railLen', railLen, ...
        'heading', deg2rad(headingDeg), ...
        'inclination', deg2rad(inclDeg), ...
        'windMu', windMu, ...
        'windSigma', windSigma, ...
        'rho', 1.225, ...
        'aSound', 340.0, ...
        'g', 9.80665, ...
        'thrustTime', data.thrustTime(:), ...
        'thrustN', data.thrustN(:), ...
        'dragMach', data.dragMach(:), ...
        'dragCd', data.dragCd(:), ...
        'recoveryCdA', 0.08, ...
        'recoveryMode', lower(string(data.ork.recoveryEvent)), ...
        'recoveryDelay', data.ork.recoveryDelay, ...
        'cpBase', 0.75*length, ...
        'cpRecovery', 0.85*length, ...
        'cgDry', 0.55*length, ...
        'cgProp', 0.80*length ...
    );
end

function [results, sample] = runMonteCarlo(data, nIter, usePar)
    mdl = data.model;
    results(1,nIter) = struct('apogee',NaN,'tApogee',NaN,'stabilityBoostMin',NaN,'stabilityRecoveryMin',NaN);

    if usePar
        parfor k = 1:nIter
            results(k) = oneRun(mdl, true);
        end
    else
        for k = 1:nIter
            results(k) = oneRun(mdl, true);
        end
    end

    sample = oneRun(mdl, false);
end

function out = oneRun(mdl, randomize)
    if randomize
        mDry = mdl.mDry * (1 + 0.03*randn());
        mProp = mdl.mProp * (1 + 0.05*randn());
        cdScale = max(0.7, 1 + 0.08*randn());
        wind = max(0, mdl.windMu + mdl.windSigma*randn());
        inc = mdl.inclination + deg2rad(0.6*randn());
        heading = mdl.heading + deg2rad(2.0*randn());
    else
        mDry = mdl.mDry;
        mProp = mdl.mProp;
        cdScale = 1.0;
        wind = mdl.windMu;
        inc = mdl.inclination;
        heading = mdl.heading;
    end

    uLaunch = [cos(inc)*cos(heading), cos(inc)*sin(heading), sin(inc)];
    if norm(uLaunch) < 1e-12, uLaunch = [0 0 1]; else, uLaunch = uLaunch/norm(uLaunch); end

    x0 = [0 0 0 0 0 0 mDry+mProp]';
    tEnd = 400;

    opts = odeset('Events', @(t,x)eventGround(t,x));
    [t,x] = ode45(@(t,x)dynamics(t,x,mdl,mDry,mProp,cdScale,wind,uLaunch), [0 tEnd], x0, opts);

    z = x(:,3);
    [apogee, iA] = max(z);
    tApogee = t(iA);

    if mdl.recoveryMode == "apogee"
        tRecovery = tApogee + mdl.recoveryDelay;
    else
        tRecovery = mdl.burnTime + max(0.1, mdl.recoveryDelay);
    end

    mPropT = max(0, mProp*(1 - t./max(mdl.burnTime,eps)));
    cg = (mdl.cgDry*mDry + mdl.cgProp.*mPropT) ./ (mDry + mPropT + eps);

    cp = mdl.cpBase*ones(size(t));
    cp(t > tRecovery) = mdl.cpRecovery;

    stability = (cp - cg) ./ max(2*mdl.radius, eps);

    pre = stability(t<=tRecovery);
    post = stability(t>tRecovery);
    if isempty(pre), pre = NaN; end
    if isempty(post), post = NaN; end

    out = struct();
    out.apogee = apogee;
    out.tApogee = tApogee;
    out.stabilityBoostMin = min(pre);
    out.stabilityRecoveryMin = min(post);

    out.t = t;
    out.xyz = x(:,1:3);
    out.cp = cp;
    out.cg = cg;
    out.stability = stability;
    out.tRecovery = tRecovery;
    out.iApogee = iA;
end

function dx = dynamics(t, x, mdl, mDry, mProp0, cdScale, wind, uLaunch)
    pos = x(1:3);
    vel = x(4:6);

    mProp = max(0, mProp0*(1 - t/max(mdl.burnTime,eps)));
    m = mDry + mProp;

    thrust = interp1(mdl.thrustTime, mdl.thrustN, t, 'linear', 0);
    if t > mdl.burnTime, thrust = 0; end

    vWind = [wind 0 0]';
    vRel = vel - vWind;
    speed = norm(vRel);
    mach = speed/mdl.aSound;

    cd = interp1(mdl.dragMach, mdl.dragCd, mach, 'linear', 'extrap');
    cd = max(0.05, cdScale*cd);

    if thrust <= 0 && pos(3) > 0 && vel(3) < 0
        cdA = max(mdl.recoveryCdA, cd*mdl.areaRef);
    else
        cdA = cd*mdl.areaRef;
    end

    drag = -0.5*mdl.rho*cdA*speed*vRel;
    grav = [0 0 -m*mdl.g]';
    thrustVec = thrust * uLaunch(:);

    acc = (thrustVec + drag + grav) / m;

    mdot = -mProp0/max(mdl.burnTime,eps);
    if t > mdl.burnTime, mdot = 0; end

    dx = [vel; acc; mdot];
end

function [value,isterminal,direction] = eventGround(~,x)
    value = x(3);
    isterminal = 1;
    direction = -1;
end

function val = tryGet(S, pathCell, defaultVal)
    val = defaultVal;
    try
        X = S;
        for i = 1:numel(pathCell)
            f = pathCell{i};
            if isstruct(X) && isfield(X,f)
                X = X.(f);
            else
                return;
            end
        end
        if isempty(X), return; end
        if ischar(X) || isstring(X)
            xn = str2double(string(X));
            if ~isnan(xn), val = xn; else, val = X; end
        else
            val = X;
        end
    catch
    end
end

function v = askNumeric(prompt, defaultV)
    a = inputdlg(prompt, 'Additional Input Needed', [1 50], {num2str(defaultV)});
    if isempty(a)
        error('User cancelled input prompt: %s', prompt);
    end
    v = str2double(a{1});
    if isnan(v)
        error('Invalid numeric value for prompt: %s', prompt);
    end
end

function num = readFirstNumeric(xDoc, tagName)
    num = NaN;
    try
        elems = xDoc.getElementsByTagName(tagName);
        if elems.getLength > 0
            txt = char(elems.item(0).getTextContent);
            num = str2double(strtrim(txt));
        end
    catch
    end
end

function txt = readFirstText(xDoc, tagName)
    txt = '';
    try
        elems = xDoc.getElementsByTagName(tagName);
        if elems.getLength > 0
            txt = strtrim(char(elems.item(0).getTextContent));
        end
    catch
    end
end