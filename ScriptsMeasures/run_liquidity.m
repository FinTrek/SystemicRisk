% [INPUT]
% ds = A structure representing the dataset.
% temp = A string representing the full path to the Excel spreadsheet used as a template for the results file.
% out = A string representing the full path to the Excel spreadsheet to which the results are written, eventually replacing the previous ones.
% bwl = An integer [90,252] representing the dimension of the long bandwidth (optional, default=252).
% bwm = An integer [21,90) representing the dimension of the medium bandwidth (optional, default=21).
% bws = An integer [5,21) representing the dimension of the short bandwidth (optional, default=5).
% mem = A string ('B' for Baseline MEM, 'A' for Asymmetric MEM, 'P' for Asymmetric Power MEM, 'S' for Spline MEM) representing the MEM type used to calculate the ILLIQ (optional, default='B').
% w = An integer [500,Inf) representing the number of sweeps used to calculate the RIS (optional, default=500).
% c = A float (0,Inf) representing the starting coefficient value used to calculate the RIS (optional, default=0.01).
% s2 = A float (0,Inf) representing the starting variance of innovations used to calculate the RIS (optional, default=0.0004).
% analyze = A boolean that indicates whether to analyse the results and display plots (optional, default=false).
%
% [OUTPUT]
% result = A structure representing the original dataset inclusive of intermediate and final calculations.
% stopped = A boolean that indicates whether the process has been stopped through user input.

function [result,stopped] = run_liquidity(varargin)

    persistent ip;

    if (isempty(ip))
        ip = inputParser();
        ip.addRequired('ds',@(x)validateattributes(x,{'struct'},{'nonempty'}));
        ip.addRequired('temp',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        ip.addRequired('out',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        ip.addOptional('bwl',252,@(x)validateattributes(x,{'double'},{'real','finite','integer','>=',90,'<=',252,'scalar'}));
        ip.addOptional('bwm',21,@(x)validateattributes(x,{'double'},{'real','finite','integer','>=',21,'<',90,'scalar'}));
        ip.addOptional('bws',5,@(x)validateattributes(x,{'double'},{'real','finite','integer','>=',5,'<',21,'scalar'}));
        ip.addOptional('mem','B',@(x)any(validatestring(x,{'A','B','P','S'})));
        ip.addOptional('w',500,@(x)validateattributes(x,{'double'},{'real','finite','integer','>=',500}));
        ip.addOptional('c',0.01,@(x)validateattributes(x,{'double'},{'real','finite','positive'}));
        ip.addOptional('s2',0.0004,@(x)validateattributes(x,{'double'},{'real','finite','positive'}));
        ip.addOptional('analyze',false,@(x)validateattributes(x,{'logical'},{'scalar'}));
    end

    ip.parse(varargin{:});

    ipr = ip.Results;
    ds = validate_dataset(ipr.ds,'cross-sectional');
    temp = validate_template(ipr.temp);
    out = validate_output(ipr.out);
    [bwl,bwm,bws] = validate_bandwidths(ipr.bwl,ipr.bwm,ipr.bws);
    mem = ipr.mem;
    w = ipr.w;
    c = ipr.c;
    s2 = ipr.s2;
    analyze = ipr.analyze;
    
    nargoutchk(1,2);

    [result,stopped] = run_liquidity_internal(ds,temp,out,bwl,bwm,bws,mem,w,c,s2,analyze);

end

function [result,stopped] = run_liquidity_internal(ds,temp,out,bwl,bwm,bws,mem,w,c,s2,analyze)

    result = [];
    stopped = false;
    e = [];

    ds = initialize(ds,bwl,bwm,bws,mem,w,c,s2);
    n = ds.N;
    t = ds.T;

    bar = waitbar(0,'Initializing liquidity measures...','CreateCancelBtn',@(src,event)setappdata(gcbf(),'Stop', true));
    setappdata(bar,'Stop',false);
	cleanup = onCleanup(@()delete(bar));
    
    pause(1);
    waitbar(0,bar,'Calculating liquidity measures...');
    pause(1);

    try
        
        ci = ds.CI;

        r = ds.Returns;
        p = ds.Prices;
        v = ds.Volumes;
        cp = ds.Capitalizations;
        sv = ds.StateVariables;
        
        mag_r = floor(round((log(abs(r(:))) ./ log(10)),15));
        mag_r(~isfinite(mag_r)) = [];
        mag_r = round(abs(mean(mag_r)),0);

        mag_v = floor(round((log(abs(v(:))) ./ log(10)),15));
        mag_v(~isfinite(mag_v)) = [];
        mag_v = round(mean(mag_v),0);

        mag = 10^(mag_r + mag_v);

        for i = 1:n
            waitbar((i - 1) / n,bar,['Calculating liquidity measures for ' ds.FirmNames{i} '...']);

            if (getappdata(bar,'Stop'))
                stopped = true;
                break;
            end
            
            offset = min(ds.Defaults(i) - 1,t);

            r_x = r(1:offset,i);
            p_x = p(1:offset,i);
            v_x = v(1:offset,i);
            cp_x = cp(1:offset,i);
            
            ds.HHLR(1:offset,i) = calculate_hhlr(p_x,v_x,cp_x,ds.BWL,ds.BWS);
 
            if (ci)
                sv_x = sv(1:offset,:);
                [illiq,illiq_covariates,knots] = calculate_illiq(r_x,v_x,sv_x,mag,ds.BWM,ds.MEM);
                
                ds.ILLIQ(1:offset,i) = illiq;
                ds.ILLIQCovariates(1:offset,i) = illiq_covariates;
                
                if (~isempty(knots))
                    ds.ILLIQKnots(i) = knots(1);
                    ds.ILLIQCovariatesKnots(i) = knots(2);
                end
            else
                [illiq,~,knots] = calculate_illiq(r_x,v_x,[],mag,ds.BWM,ds.MEM);
                
                ds.ILLIQ(1:offset,i) = illiq;
                
                if (~isempty(knots))
                    ds.ILLIQKnots(i) = knots(1);
                end
            end

            ds.RIS(1:offset,i) = calculate_ris(p_x,ds.BWL,ds.SW,ds.C,ds.S2);
            ds.TR(1:offset,i) = calculate_tr(v_x,cp_x,ds.BWL);
            ds.VR(1:offset,i) = calculate_vr(r_x,ds.BWL,ds.BWM);
            
            if (getappdata(bar,'Stop'))
                stopped = true;
                break;
            end
            
            waitbar(i / n,bar);
        end

    catch e
    end

    if (~isempty(e))
        delete(bar);
        rethrow(e);
    end
    
    if (stopped)
        delete(bar);
        return;
    end

    pause(1);
    waitbar(1,bar,'Finalizing liquidity measures...');
    pause(1);

    try
        ds = finalize(ds);
    catch e
        delete(bar);
        rethrow(e);
    end
    
    pause(1);
    waitbar(1,bar,'Writing liquidity measures...');
    pause(1);
    
    try
        write_results(ds,temp,out);
        delete(bar);
    catch e
        delete(bar);
        rethrow(e);
    end
    
    if (analyze)
        safe_plot(@(id)plot_averages(ds,id));
        safe_plot(@(id)plot_sequence_other(ds,'HHLR',id));
        safe_plot(@(id)plot_sequence_illiq(ds,id));
        safe_plot(@(id)plot_sequence_other(ds,'RIS',id));
        safe_plot(@(id)plot_sequence_other(ds,'TR',id));
        safe_plot(@(id)plot_sequence_other(ds,'VR',id));
    end
    
    result = ds;

end

%% DATA

function ds = initialize(ds,bwl,bwm,bws,mem,w,c,s2)

    n = ds.N;
    t = ds.T;

    ds.CI = ~isempty(ds.StateVariables);
    ds.BWL = bwl;
    ds.BWM = bwm;
    ds.BWS = bws;
    ds.C = c;
    ds.MEM = mem;
    ds.S2 = s2;
    ds.SW = w;
    
    ds.LabelsSimple = {'HHLR' 'ILLIQ'  'RIS' 'TR' 'VR' 'Averages'};
    ds.Labels = {'HHLR' ['ILLIQ (MEM=' ds.MEM ')'] 'RIS' 'TR' 'VR' 'Averages'};

    ds.HHLR = NaN(t,n);
    ds.ILLIQ = NaN(t,n);
    
    if (strcmp(ds.MEM,'S'))
        ds.ILLIQKnots = NaN(1,n);
    end
    
    if (ds.CI)
        ds.LabelsSimple = [ds.LabelsSimple(1:2) {'ILLIQ Covariates'} ds.LabelsSimple(3:end)];
        ds.Labels = [ds.Labels(1:2) {['ILLIQ Covariates (MEM=' ds.MEM ')']} ds.Labels(3:end)];
        
        ds.ILLIQCovariates = NaN(t,n);
        
        if (strcmp(ds.MEM,'S'))
            ds.ILLIQCovariatesKnots = NaN(1,n);
        end
    end
    
    ds.RIS = NaN(t,n);
    ds.TR = NaN(t,n);
    ds.VR = NaN(t,n);
    
    ds.Averages = NaN(t,numel(ds.LabelsSimple) - 1);

end

function ds = finalize(ds)

    n = ds.N;

    weights = max(0,ds.Capitalizations ./ repmat(sum(ds.Capitalizations,2,'omitnan'),1,n));

    hhlr_avg = sum(ds.HHLR .* weights,2,'omitnan');
    hhlr_avg = (hhlr_avg - min(hhlr_avg)) ./ (max(hhlr_avg) - min(hhlr_avg));

    illiq_avg = sum(ds.ILLIQ .* weights,2,'omitnan');
    illiq_avg = (illiq_avg - min(illiq_avg)) ./ (max(illiq_avg) - min(illiq_avg));
    
    ris_avg = sum(ds.RIS .* weights,2,'omitnan');

    tr_avg = sum(ds.TR .* weights,2,'omitnan');
    tr_avg = (tr_avg - min(tr_avg)) ./ (max(tr_avg) - min(tr_avg));

    vr_avg = sum(ds.VR .* weights,2,'omitnan');    
    
    if (ds.CI)
        illiq_covariates_avg = sum(ds.ILLIQCovariates .* weights,2,'omitnan');
        illiq_covariates_avg = (illiq_covariates_avg - min(illiq_covariates_avg)) ./ (max(illiq_covariates_avg) - min(illiq_covariates_avg));

        ds.Averages = [hhlr_avg illiq_avg illiq_covariates_avg ris_avg tr_avg vr_avg];
    else
        ds.Averages = [hhlr_avg illiq_avg ris_avg tr_avg vr_avg];
    end

end

function [bwl,bwm,bws] = validate_bandwidths(bwl,bwm,bws)

    if (bwl < (bwm * 2))
        error(['The long bandwidth (' num2str(bwl) ') must be at least twice the medium bandwidth (' num2str(bwm) ').']);
    end
  
    if (bwm < (bws * 2))
        error(['The medium bandwidth (' num2str(bwm) ') must be at least twice the short bandwidth (' num2str(bws) ').']);
    end
    
end

function out = validate_output(out)

    [path,name,extension] = fileparts(out);

    if (~strcmp(extension,'.xlsx'))
        out = fullfile(path,[name extension '.xlsx']);
    end
    
end

function temp = validate_template(temp)

    if (exist(temp,'file') == 0)
        error('The template file could not be found.');
    end
    
    if (ispc())
        [file_status,file_sheets,file_format] = xlsfinfo(temp);
        
        if (isempty(file_status) || ~strcmp(file_format,'xlOpenXMLWorkbook'))
            error('The template file is not a valid Excel spreadsheet.');
        end
    else
        [file_status,file_sheets] = xlsfinfo(temp);
        
        if (isempty(file_status))
            error('The template file is not a valid Excel spreadsheet.');
        end
    end

    sheets = {'HHLR' 'ILLIQ' 'ILLIQ Covariates' 'RIS' 'TR' 'VR' 'Averages'};
    
    if (~all(ismember(sheets,file_sheets)))
        error(['The template must contain the following sheets: ' sheets{1} sprintf(', %s',sheets{2:end}) '.']);
    end
    
    if (ispc())
        try
            excel = actxserver('Excel.Application');
            excel_wb = excel.Workbooks.Open(temp,0,false);

            for i = 1:numel(sheets)
                excel_wb.Sheets.Item(sheets{i}).Cells.Clear();
            end
            
            excel_wb.Save();
            excel_wb.Close();
            excel.Quit();

            delete(excel);
        catch
        end
    end

end

function write_results(ds,temp,out)

    [out_path,~,~] = fileparts(out);

    try
        if (exist(out_path,'dir') ~= 7)
            mkdir(out_path);
        end

        if (exist(out,'file') == 2)
            delete(out);
        end
    catch
        error('A system I/O error occurred while writing the results.');
    end
    
    copy_result = copyfile(temp,out,'f');
    
    if (copy_result == 0)
        error('The output file could not be created from the template file.');
    end

    dates_str = cell2table(ds.DatesStr,'VariableNames',{'Date'});

    for i = 1:(numel(ds.Labels) - 1)
        sheet = ds.LabelsSimple{i};
        measure = strrep(sheet,' ','');

        tab = [dates_str array2table(ds.(measure),'VariableNames',ds.FirmNames)];
        writetable(tab,out,'FileType','spreadsheet','Sheet',sheet,'WriteRowNames',true);
    end

    tab = [dates_str array2table(ds.Averages,'VariableNames',strrep(ds.LabelsSimple(1:end-1),' ','_'))];
    writetable(tab,out,'FileType','spreadsheet','Sheet','Averages','WriteRowNames',true);    

    if (~ds.CI && ispc())
        try
            excel = actxserver('Excel.Application');
        catch
            return;
        end

        try
            exc_wb = excel.Workbooks.Open(out,0,false);

            exc_wb.Sheets.Item('ILLIQ Covariates').Delete();
            
            for i = 1:numel(ds.LabelsSimple)
                exc_wb.Sheets.Item(ds.LabelsSimple{i}).Name = ds.Labels{i};
            end
            
            exc_wb.Save();
            exc_wb.Close();
            excel.Quit();
        catch
        end
        
        try
            delete(excel);
        catch
        end
    end

end

%% MEASURES

function hhlr = calculate_hhlr(p,v,cp,bwl,bws)

	tr = v ./ cp;
	tr(~isfinite(tr)) = 0;

    windows_p = extract_rolling_windows(p,bws);
    dp = cellfun(@(x)(max(x) - min(x)) / min(x),windows_p);
    
	alpha = 2 / (bwl + 1);

    hhlr = dp ./ tr;
    hhlr(~isfinite(hhlr)) = 0;
    hhlr(1:bws) = mean(hhlr(bws+1:bws*2+1));
    hhlr = [hhlr(1); filter(alpha,[1 (alpha - 1)],hhlr(2:end),(1 - alpha) * hhlr(1))];
    hhlr = (hhlr - min(hhlr)) ./ (max(hhlr) - min(hhlr));
    
end

function [illiq,illiq_covariates,knots] = calculate_illiq(r,v,sv,mag,bwm,mem)

    alpha = 2 / (bwm + 1);

    input = mag .* (abs(r) ./ v);
    input(~isfinite(input) | (input == 0)) = NaN;
    input(isnan(input)) = mean(input,'omitnan');
    
    if (any(strcmp(mem,{'A' 'P'})))
        input = [input r];
    end
    
    knots = [];

    [illiq,~,mem_params] = multiplicative_error(input,mem);
    illiq = [illiq(1); filter(alpha,[1 (alpha - 1)],illiq(2:end),(1 - alpha) * illiq(1))];
	illiq = (illiq - min(illiq)) ./ (max(illiq) - min(illiq));
    
    if (strcmp(mem,'S'))
        knots(1) = mem_params(1);
    end
    
    if (isempty(sv))
        illiq_covariates = [];
    else
        [illiq_covariates,~,mem_params] = multiplicative_error([input sv],mem);
        illiq_covariates = [illiq_covariates(1); filter(alpha,[1 (alpha - 1)],illiq_covariates(2:end),(1 - alpha) * illiq_covariates(1))];
        illiq_covariates = (illiq_covariates - min(illiq_covariates)) ./ (max(illiq_covariates) - min(illiq_covariates));
        
        if (strcmp(mem,'S'))
            knots(2) = mem_params(1);
        end
    end

end

function ris = calculate_ris(p,bwl,sw,c,s2)

    windows = extract_rolling_windows(log(max(1e-6,p)),bwl);
    ris = zeros(numel(windows),1);

    parfor i = 1:numel(windows)
        ris(i) = roll_gibbs(windows{i},sw,c,s2);
    end

    alpha = 2 / (bwl + 1);
    ris = [ris(1); filter(alpha,[1 (alpha - 1)],ris(2:end),(1 - alpha) * ris(1))];

end

function tr = calculate_tr(v,cp,bwl)

    alpha = 2 / (bwl + 1);

	tr = v ./ cp;
	tr(~isfinite(tr)) = 0;
    tr = [tr(1); filter(alpha,[1 (alpha - 1)],tr(2:end),(1 - alpha) * tr(1))];
    tr = (tr - min(tr)) ./ (max(tr) - min(tr));

end

function vr = calculate_vr(r,bwl,bwm)

    alpha = 2 / (bwl + 1);
    t = bwl / bwm;

    windows_long = extract_rolling_windows(r,bwl);
    var_long = cellfun(@var,windows_long);
    
    windows_short = extract_rolling_windows(r,bwm);
    var_short = cellfun(@var,windows_short);

	vr = var_long ./ (t .* var_short);
    vr(~isfinite(vr)) = 0;
    vr(1:bwm) = mean(vr(bwm+1:bwm*2+1));
    vr = [vr(1); filter(alpha,[1 (alpha - 1)],vr(2:end),(1 - alpha) * vr(1))];

end

%% PLOTTING

function plot_averages(ds,id)

    hhlr = ds.Averages(:,1);
    illiq = ds.Averages(:,find(strcmp('ILLIQ',ds.LabelsSimple),1,'first'));
    ris = ds.Averages(:,find(strcmp('RIS',ds.LabelsSimple),1,'first'));
    tr = ds.Averages(:,find(strcmp('TR',ds.LabelsSimple),1,'first'));
    vr = ds.Averages(:,find(strcmp('VR',ds.LabelsSimple),1,'first'));

    f = figure('Name','Liquidity Measures > Averages','Units','normalized','Position',[100 100 0.85 0.85],'Tag',id);
    
    if (ds.CI)
        illiq_covariates = ds.Averages(:,find(strcmp('ILLIQ Covariates',ds.LabelsSimple),1,'first'));
        
        indices = (abs(illiq_covariates - illiq) > 0.01);
        illiq_delta = NaN(ds.T,1);
        illiq_delta(indices) = illiq_covariates(indices);
        
        sub_1 = subplot(3,2,1);
        plot(sub_1,ds.DatesNum,illiq,'Color',[0.000 0.447 0.741]);
        set(sub_1,'YLim',[0 1.1]);
        title(sub_1,ds.Labels{2});
        
        sub_6 = subplot(3,2,2);
        plot(sub_6,ds.DatesNum,illiq_covariates,'Color',[0.000 0.447 0.741]);
        hold on;
            plot(sub_6,ds.DatesNum,illiq_delta,'Color',[0.494 0.184 0.556]);
        hold off;
        set(sub_6,'YLim',[0 1.1]);
        title(sub_6,ds.Labels{3});
    else
        sub_1 = subplot(3,2,1:2);
        plot(sub_1,ds.DatesNum,illiq,'Color',[0.000 0.447 0.741]);
        set(sub_1,'YLim',[0 1.1]);
        title(sub_1,ds.Labels{2});
    end

    sub_2 = subplot(3,2,3);
    plot(sub_2,ds.DatesNum,hhlr,'Color',[0.000 0.447 0.741]);
    set(sub_2,'YLim',[0 1]);
    title(sub_2,ds.Labels{1});
    
    sub_3 = subplot(3,2,4);
    plot(sub_3,ds.DatesNum,ris,'Color',[0.000 0.447 0.741]);
    set(sub_3,'YLim',plot_limits(ris,0.1,0));
    title(sub_3,ds.Labels{4});
    
    sub_4 = subplot(3,2,5);
    plot(sub_4,ds.DatesNum,tr,'Color',[0.000 0.447 0.741]);
    set(sub_4,'YLim',[0 1]);
    title(sub_4,ds.Labels{5});

    sub_5 = subplot(3,2,6);
    plot(sub_5,ds.DatesNum,vr,'Color',[0.000 0.447 0.741]);
    set(sub_5,'YLim',plot_limits(vr,0.1,0));
    title(sub_5,ds.Labels{6});
    
    set([sub_1 sub_2 sub_3 sub_4 sub_5],'XLim',[ds.DatesNum(1) ds.DatesNum(end)],'XTickLabelRotation',45);
    set([sub_1 sub_2 sub_3 sub_4 sub_5],'XGrid','on','YGrid','on');
    
    if (ds.CI)
        set([sub_1 sub_2 sub_3 sub_4 sub_5 sub_6],'XLim',[ds.DatesNum(1) ds.DatesNum(end)],'XTickLabelRotation',45);
        set([sub_1 sub_2 sub_3 sub_4 sub_5 sub_6],'XGrid','on','YGrid','on');
    else
        set([sub_1 sub_2 sub_3 sub_4 sub_5],'XLim',[ds.DatesNum(1) ds.DatesNum(end)],'XTickLabelRotation',45);
        set([sub_1 sub_2 sub_3 sub_4 sub_5],'XGrid','on','YGrid','on');
    end

    if (ds.MonthlyTicks)
        if (ds.CI)
            date_ticks([sub_1 sub_2 sub_3 sub_4 sub_5 sub_6],'x','mm/yyyy','KeepLimits','KeepTicks');
        else
            date_ticks([sub_1 sub_2 sub_3 sub_4 sub_5],'x','mm/yyyy','KeepLimits','KeepTicks');
        end
    else
        if (ds.CI)
            date_ticks([sub_1 sub_2 sub_3 sub_4 sub_5 sub_6],'x','yyyy','KeepLimits');
        else
            date_ticks([sub_1 sub_2 sub_3 sub_4 sub_5],'x','yyyy','KeepLimits');
        end
    end

    figure_title('Averages');

    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end

function plot_sequence_illiq(ds,id)

    ds.CI = false;
    ds.MEM = 'A';

    n = ds.N;
    t = ds.T;
    dn = ds.DatesNum;
    mt = ds.MonthlyTicks;

    if (ds.CI)
        k = 2;
        
        data = [repmat({dn},1,n); mat2cell(ds.ILLIQ,t,ones(1,n)); mat2cell(ds.ILLIQCovariates,t,ones(1,n))];
        
        plots_allocation = [2 1];
        plots_span = {1 2};
  
        if (strcmp(ds.MEM,'S'))
            label_1 = strrep(ds.Labels{2},')','');
            titles_1 = arrayfun(@(x)sprintf([label_1 ', KNOTS=%d)'],x),ds.ILLIQKnots,'UniformOutput',false);
            label_2 = strrep(ds.Labels{3},')','');
            titles_2 = arrayfun(@(x)sprintf([label_2 ', KNOTS=%d)'],x),ds.ILLIQCovariatesKnots,'UniformOutput',false);
            plots_title = [titles_1; titles_2];
        else
            plots_title = [repmat(ds.Labels(2),1,n); repmat(ds.Labels(3),1,n)];
        end
    else
        k = 1;
        
        data = [repmat({dn},1,n); mat2cell(ds.ILLIQ,t,ones(1,n))];
        
        plots_allocation = [1 1];
        plots_span = {1};

        if (strcmp(ds.MEM,'S'))
            label = strrep(ds.Labels{2},')','');
            plots_title = arrayfun(@(x)sprintf([label ', KNOTS=%d)'],x),ds.ILLIQKnots,'UniformOutput',false);
        else
            plots_title = repmat(ds.Labels(2),1,n);
        end
    end
    
    empty_param = repmat({[]},1,k);

    x_dates = repmat({mt},1,k);
    x_grid = repmat({true},1,k);
    x_limits = repmat({[dn(1) dn(end)]},1,k);
    x_rotation = repmat({45},1,k);
    
    y_grid = repmat({true},1,k);
    y_limits = repmat({[0 1]},1,k);
    
    core = struct();

    core.N = n;
    core.Data = data;
    core.Function = @(subs,data)plot_function(subs,data,k);

    core.OuterTitle = 'Liquidity Measures > ILLIQ Time Series';
    core.InnerTitle = 'ILLIQ Time Series';
    core.SequenceTitles = ds.FirmNames;

    core.PlotsAllocation = plots_allocation;
    core.PlotsSpan = plots_span;
    core.PlotsTitle = plots_title;

    core.XDates = x_dates;
    core.XGrid = x_grid;
    core.XLabel = empty_param;
    core.XLimits = x_limits;
    core.XRotation = x_rotation;
    core.XTick = empty_param;
    core.XTickLabels = empty_param;

    core.YGrid = y_grid;
    core.YLabel = empty_param;
    core.YLimits = y_limits;
    core.YRotation = empty_param;
    core.YTick = empty_param;
    core.YTickLabels = empty_param;

    sequential_plot(core,id);
    
    function plot_function(subs,data,k)

        x = data{1};
        y1 = data{2};
        
        d = find(isnan(y1),1,'first');
        
        if (isempty(d))
            xd = [];
        else
            xd = x(d) - 1;
        end
        
        plot(subs(1),x,y1,'Color',[0.000 0.447 0.741]);
        
        if (~isempty(xd))
            hold(subs(1),'on');
                plot(subs(1),[xd xd],get(subs(1),'YLim'),'Color',[1 0.4 0.4]);
            hold(subs(1),'off');
        end

        if (k == 2)
            y2 = data{3};
            
            indices = (abs(y2 - y1) > 0.01);
            delta = NaN(numel(y2),1);
            delta(indices) = y2(indices);
            
            plot(subs(2),x,y2,'Color',[0.000 0.447 0.741]);

            hold(subs(2),'on');
                plot(subs(2),x,delta,'Color',[0.494 0.184 0.556]);
                if (~isempty(xd))
                    plot(subs(2),[xd xd],get(subs(2),'YLim'),'Color',[1 0.4 0.4]);
                end
            hold(subs(2),'off');
        end

    end

end

function plot_sequence_other(ds,target,id)

    n = ds.N;
    t = ds.T;
    dn = ds.DatesNum;
    mt = ds.MonthlyTicks;
    ts = ds.(strrep(target,' ',''));

	data = [repmat({dn},1,n); mat2cell(ts,t,ones(1,n))];

    plots_title = repmat(ds.Labels(find(strcmp(target,ds.LabelsSimple),1,'first')),1,n);
    
    x_limits = [dn(1) dn(end)];
    
    if (strcmp(target,'HHLR') || strcmp(target,'TR'))
        y_limits = [0 1];
    else
        y_limits = plot_limits(ts,0.1,0);
    end
    
    core = struct();

    core.N = n;
    core.Data = data;
    core.Function = @(subs,data)plot_function(subs,data);

    core.OuterTitle = ['Liquidity Measures > ' target ' Time Series'];
    core.InnerTitle = [target ' Time Series'];
    core.SequenceTitles = ds.FirmNames;

    core.PlotsAllocation = [1 1];
    core.PlotsSpan = {1};
    core.PlotsTitle = plots_title;

    core.XDates = {mt};
    core.XGrid = {true};
    core.XLabel = {[]};
    core.XLimits = {x_limits};
    core.XRotation = {45};
    core.XTick = {[]};
    core.XTickLabels = {[]};

    core.YGrid = {true};
    core.YLabel = {[]};
    core.YLimits = {y_limits};
    core.YRotation = {[]};
    core.YTick = {[]};
    core.YTickLabels = {[]};

    sequential_plot(core,id);
    
    function plot_function(subs,data)
        
        x = data{1};
        y = data{2};
        
        d = find(isnan(y),1,'first');
        
        if (isempty(d))
            xd = [];
        else
            xd = x(d) - 1;
        end

        plot(subs(1),x,y,'Color',[0.000 0.447 0.741]);

        if (~isempty(xd))
            hold(subs(1),'on');
                plot(subs(1),[xd xd],get(subs(1),'YLim'),'Color',[1 0.4 0.4]);
            hold(subs(1),'off');
        end

    end

end
