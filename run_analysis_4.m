clc; clear; close all;

warning off;

% Settings
folder = '.';
sampling_interval_ps = 4;
time_ns = (0:24999) * sampling_interval_ps * 1e-3; % 0 to 100 ns
sigma = 4;
fit_configs = {'poly2', 'poly3', 'poly4', 'poly5', 'poly6', 'poly7', 'poly8', 'poly9', 'fourier1', 'fourier2', 'fourier3', 'fourier4', 'fourier5', 'fourier6', 'gauss1'};
plot_fit_type = 'poly2';

% Collect files
files = dir(fullfile(folder, '*.csv'));
dist_map = containers.Map('KeyType', 'double', 'ValueType', 'any');
for k = 1:length(files)
    fname = files(k).name;
    tokens = regexp(fname, 'distance_(\d+)_\d.csv', 'tokens');
    if ~isempty(tokens)
        d = str2double(tokens{1}{1})*2*2.54;
        if ~isKey(dist_map, d)
            dist_map(d) = {};
        end
        tmp_list = dist_map(d);
        tmp_list{end+1} = fullfile(folder, fname);
        dist_map(d) = tmp_list;
    end
end

% Prepare maps and results
results = {};
speed_results = {};
plot_arrival_map = containers.Map('KeyType','double','ValueType','double');
plot_gradient_map = containers.Map('KeyType','double','ValueType','any');
plot_fit_objs = containers.Map('KeyType','double','ValueType','any');
plot_fit_x = containers.Map('KeyType','double','ValueType','any');
plot_fit_y = containers.Map('KeyType','double','ValueType','any');
c_theo = 299792458;

for f = 1:length(fit_configs)
    fit_label = fit_configs{f};
    arrival_map = containers.Map('KeyType', 'double', 'ValueType', 'double');

    dist_keys = keys(dist_map);
    for i = 1:length(dist_keys)
        d = dist_keys{i};
        sig_list = dist_map(d);
        all_peaks = []; all_qualities = []; all_signals = [];

        for j = 1:length(sig_list)
            s = load(sig_list{j});
            time_ns = linspace(0, 100, length(s));
            grad_sig = gradient(s', time_ns);
            smoothed = smooth(grad_sig);
            abs_smooth = smoothed;

            threshold = max(abs_smooth) * 0.99;
            [~, locs] = findpeaks(abs_smooth, 'MinPeakHeight', threshold);
            if isempty(locs), continue; end

            peak_idx = locs(1);
            coarse_peak_time = time_ns(peak_idx);
            half_window_ps = 500;
            start_time = coarse_peak_time - half_window_ps * 1e-3;
            end_time   = coarse_peak_time + half_window_ps * 1e-3;
            start_idx = find(time_ns >= start_time, 1, 'first');
            end_idx   = find(time_ns <= end_time,  1, 'last');
            if isempty(start_idx) || isempty(end_idx), continue; end

            x_win = time_ns(start_idx:end_idx)';
            y_win = abs_smooth(start_idx:end_idx);
            y_max = mymax(y_win);
            amp_cutoff = 0.4 * y_max;
            keep_mask = y_win >= amp_cutoff;
            x_filt = x_win(keep_mask);
            y_filt = y_win(keep_mask);
            if length(x_filt) < length(fit_configs), continue; end

            fit_type = fittype(fit_label);
            fit_obj = fit(x_filt, y_filt, fit_type);
            
            x_hr = linspace(min(x_filt), max(x_filt), 10000);
            y_hr = (feval(fit_obj, x_hr));
            %[~, peak_idx_hr] = mymax(y_hr);
            %peak_time = x_hr(peak_idx_hr);

            [max_val_raw, raw_idx] = max(abs_smooth(start_idx:end_idx));
            raw_peak_time = time_ns(start_idx + raw_idx - 1);


            dy_dx = (gradient(y_hr, x_hr));

            % Trouver où la dérivée est proche de zéro (minimum local d’erreur absolue)
            [~, zero_idx] = min(abs(dy_dx));
            %x = x_hr(zero_idx);
            

            % Position temporelle correspondante
            peak_time = x_hr(zero_idx);
            %peak_time = fminbnd(@(t) -feval(fit_obj, t), min(x_filt), max(x_filt));
            %[~, locs] = findpeaks(y_hr);
            %peak = locs(1);
            %peak_time = x_hr(peak);
            %fit_max_fun = @(xx) -feval(fit_obj, xx);    % negative of the fitted function
            %peak_time = fminbnd(fit_max_fun, min(x_filt), max(x_filt));
            %peak_time = fminbnd(@(xx) -feval(fit_obj, xx), min(x_filt), max(x_filt)) - 0;

            %fprintf("Raw peak: %.6f ns, Fit peak: %.6f ns, Diff: %.6f ps\n", raw_peak_time, peak_time, (peak_time - raw_peak_time)*1000);

            nrmse = goodnessOfFit(feval(fit_obj, x_filt), y_filt, 'NRMSE');

            all_peaks(end+1) = peak_time;
            all_qualities(end+1) = nrmse;
            all_signals(:, end+1) = smoothed;

            % Store fit for plotting
            if strcmp(fit_label, plot_fit_type)
                plot_fit_objs(d) = fit_obj;
                plot_fit_x(d) = x_hr;
                plot_fit_y(d) = y_hr;
            end
        end

        if isempty(all_peaks), continue; end

        arrival_mean = mean(all_peaks);
        arrival_std = std(all_peaks);
        nrmse_mean = mean(all_qualities);
        arrival_map(d) = arrival_mean;
        results(end+1, :) = {fit_label, d, arrival_mean, arrival_std, nrmse_mean};

        if strcmp(fit_label, plot_fit_type)
            plot_arrival_map(d) = arrival_mean;
            plot_gradient_map(d) = mean(all_signals, 2);
        end
    end

    % Linear fit delay vs distance
    all_dist = sort(cell2mat(keys(arrival_map)));
    if length(all_dist) < 2, continue; end
    lol = 026*2.54*2;
    if any(all_dist == lol), all_dist(all_dist == 300) = []; end

    delays = arrayfun(@(d) arrival_map(d), all_dist);
    ref_time = arrival_map(min(all_dist));
    rel_delays = delays - ref_time;

    ft = fittype('a*(x-c) + b', 'independent', 'x', 'dependent', 'y', 'coefficients', {'a','b', 'c'});
    startpoints = [1/(c_theo), 0, 1];
    [lin_fit, gof] = fit(all_dist', rel_delays', ft, 'StartPoint', startpoints);
    slope = lin_fit.a;
    intercept = lin_fit.b;
    speed_mps = 1 / (slope * 1e-8 / 1e-1);
    err_percent = abs((speed_mps - c_theo) / c_theo) * 100;
    speed_results(end+1,:) = {fit_label, speed_mps, c_theo, err_percent, gof.rmse};

    if strcmp(fit_label, plot_fit_type)
        plot_distances = all_dist;
        plot_delays = rel_delays;
        plot_delay_errors = zeros(size(rel_delays));
        for i_plot = 1:length(all_dist)
            idx = find(strcmp(results(:,1), plot_fit_type) & [results{:,2}]' == all_dist(i_plot));
            if ~isempty(idx)
                plot_delay_errors(i_plot) = results{idx, 4};
            end
        end
        plot_lin_slope = slope;
        plot_lin_intercept = intercept;
        % --- Ajouter incertitude des longueurs ---
        distance_unc_map = containers.Map('KeyType','double','ValueType','double');
        % Now, just assign ±5 cm for every cable:
        err = 5.0*0.01;
        plot_distance_errors = repmat(err, size(plot_distances));


    end
end

% Display Tables
fprintf('\nType de fit | Longueur du câble (cm) | Temps d''arrivée (ns) | Écart-type (ns) | Qualité du fit (NRMSE)\n');
for i = 1:size(results, 1)
    fprintf('%10s | %22d | %19.4f | %15.4f | %22.4f\n', results{i,1}, results{i,2}, results{i,3}, results{i,4}, results{i,5});
end

fprintf('\nType de fit | Vitesse mesurée (m/s) | Vitesse théorique (m/s) | Erreur (%%) | Qualité du fit (NRMSE)\n');
for i = 1:size(speed_results, 1)
    fprintf('%10s | %21.8e | %24.8e | %10.5f | %22.6f\n', ...
        speed_results{i,1}, speed_results{i,2}, speed_results{i,3}, speed_results{i,4}, speed_results{i,5});
end

% Plot: Impulse Gradients + Fits
if ~isempty(plot_arrival_map)
    figure; hold on;
    keys_arr = sort(cell2mat(keys(plot_arrival_map)));
    colors = lines(length(keys_arr));
    for i = 1:length(keys_arr)
        d = keys_arr(i);
        start_val = 21;
        end_val = 23;

        % Create a logical mask for that section
        mask = (time_ns >= start_val) & (time_ns <= end_val);
        signal = plot_gradient_map(d);
        scatter(time_ns, signal, 'LineWidth', 2.5, 'Color', colors(i,:), ...
            'DisplayName', sprintf('Gradient (%d cm)', d));
        xline(plot_arrival_map(d), '--', 'Color', colors(i,:), ...
            'LineWidth', 1.5, 'DisplayName', sprintf('Pic (%d cm)', d));

        % Use stored fit results
        if isKey(plot_fit_x, d) && isKey(plot_fit_y, d)
            x_hr = plot_fit_x(d);
            y_hr = plot_fit_y(d);
            plot(x_hr, y_hr, ':', 'LineWidth', 2, 'Color', colors(i,:), ...
                'DisplayName', sprintf('Ajustement %s (%d cm)', plot_fit_type, d));
        end
    end
    ax = gca;
    c = ax.Color;
    ax.LineWidth = 2;
    xlabel('Temps (ns)', 'Interpreter', 'latex', 'FontSize', 16, 'FontWeight','bold'); 
    ylabel('Amplitude (u.a.)', 'Interpreter', 'latex', 'FontSize', 16, 'FontWeight','bold');
    %title(['Superposition des gradients lissés et ajustements — ' plot_fit_type], 'Interpreter', 'none');
    h = legend('show', 'Location', 'best', 'FontSize', 10); grid on;
    set(h, 'Units', 'normalized');
    pos = get(h, 'Position');
    pos(1:1) = pos(1:1) * 0.1;  % shrink width and height by 20%
    set(h, 'Position', pos);
    set(h, 'Visible','off');
    %set(p, 'Visible', 'off');
    fig = gcf;
    xlim([3.8 10]);
    ylim([0 0.25]);

    % Enregistrement avec exportgraphics (PNG, 300 dpi)
    exportgraphics(fig, 'fits_light.png', 'Resolution', 300);
end

% Plot: Distance vs Delay (Correct orientation) with error bars
if exist('plot_distances', 'var')
    x_fit = linspace(min(plot_distances), max(plot_distances), 100);
    y_fit = plot_lin_slope * x_fit + plot_lin_intercept;

    figure; hold on;

    % Error bar plot for both x and y
    errorbar(plot_distances, plot_delays, plot_delay_errors, plot_delay_errors, ...
             plot_distance_errors, plot_distance_errors, ...
             'p', 'Color', 'b', 'MarkerSize', 8, ...
             'DisplayName', 'Données avec Barres d’Erreur');

    plot(x_fit, y_fit, 'g-', 'LineWidth', 2, 'DisplayName', 'Ajustement Linéaire');

    ax = gca;
    c = ax.Color;
    ax.LineWidth = 2;
    xlabel("Parcourt total (cm)", 'Interpreter', 'latex', 'FontSize', 16, 'FontWeight','normal');
    ylabel('Temps de propagation (ns)', 'Interpreter', 'latex', 'FontSize', 16, 'FontWeight','bold');
    %title(['Délai vs Distance — ' plot_fit_type], 'Interpreter', 'none');
    h = legend('show', 'Location', 'best', 'FontSize', 10); 
    set(h, 'Units', 'normalized');
    pos = get(h, 'Position');
    %pos(3:4) = pos(3:4) * 0.8;  % shrink width and height by 20%
    set(h, 'Position', pos);
    %set(p, 'Visible', 'off');
    grid on;
    fig = gcf;

    % Enregistrement avec exportgraphics (PNG, 300 dpi)
    exportgraphics(fig, 'speed_light.png', 'Resolution', 300);
end

resultsTable = cell2table(results, ...
    'VariableNames', {'TypeDeFit','Distance_cm','TempsArrivee_ns','EcartType_ns','NRMSE'});

% Convert 'speed_results' to table
speedTable = cell2table(speed_results, ...
    'VariableNames', {'TypeDeFit','Vitesse_m_s','Vitesse_theo_m_s','Erreur_pct','Qualite_fit'});

% Write both to disk
writetable(resultsTable, 'resultats_arrivee.csv');
writetable(speedTable,   'resultats_vitesse.csv');

disp('CSV files created: resultats_arrivee.csv, resultats_vitesse.csv');


function [val, idx] = mymax(vec)
    % MYMAX - Find the maximum value and its index in a vector
    % Inputs:
    %   vec - A 1D array of numbers
    % Outputs:
    %   val - The maximum value
    %   idx - The index of the first occurrence of that maximum

    if isempty(vec)
        error('Input vector is empty.');
    end

    val = vec(1);
    idx = 1;

    for i = 2:length(vec)
        if vec(i) > val
            val = vec(i);
            idx = i;
        end
    end
end
