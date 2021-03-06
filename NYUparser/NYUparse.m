function data = NYUparse(data, opt)
  addpath([fileparts( mfilename('fullpath') ) '/surfaces']);
  addpath([fileparts( mfilename('fullpath') ) '/common']);
  addpath([fileparts( mfilename('fullpath') ) '/../util/nn']);
  addpath(genpath([fileparts( mfilename('fullpath') ) '/iccv07Final']));
  addpath(genpath([fileparts( mfilename('fullpath') ) '/graph_cuts']));
  addpath(genpath([fileparts( mfilename('fullpath') ) '/structure_classes']));
  addpath(genpath([fileparts( mfilename('fullpath') ) '/segmentation']));
  Consts;
  Params;
  params.seg.featureSet = consts.BFT_RGBD;
  if opt.debug, fprintf('Parsing with NYU segmentation..\n'); 
    fprintf('Extracting SIFT..\n');end
  
  % extract sift
  [~, sz] = get_projection_mask();
  sampleMask = get_sample_grid(sz(1), sz(2), ...
    params.sift.gridMargin, params.sift.stride);
  [Y, X] = ind2sub(size(sampleMask), find(sampleMask));
  coords = [X(:) Y(:)];
  imgGray = rgb2gray(im2double(data.images));
  [features, norms] = extract_sift(imgGray, coords, params.sift);
  data.siftRgb.features = features; data.siftRgb.norms = norms;
  data.siftRgb.coords = coords;
  
  imgDepth = data.depths;
  imgDepth = imgDepth - min(imgDepth(:));
  imgDepth = imgDepth ./ max(imgDepth(:));
  [features, norms] = extract_sift(imgDepth, coords, params.sift);
  data.siftD.features = features; data.siftD.norms = norms;
  data.siftD.coords = coords;
  
  p3d = rgb_plane2rgb_world_cropped(data.depths);
  X = p3d(:,1); Y = p3d(:,3); Z = p3d(:,2); 
  [imgPlanes, imgNormals, normalConf] = ...
        compute_local_planes(X, Z, Y, params);
  
  if opt.debug, fprintf('Fitting planes..\n');end
  data.planeData = rgbd2planes(im2uint8(data.images), double(data.depths), double(data.rawDepths), ...
      imgNormals, normalConf);
  planeData = data.planeData;
  planeData.siftRgb = data.siftRgb;
  planeData.siftD = data.siftD;
  
  
  points3d = swap_YZ(planeData.points3d);
  normals = swap_YZ(planeData.normals);
  normals = flip_normals_towards_interior(points3d, normals);
  
  if opt.debug, fprintf('Computing PB..\n');end
  [boundaryInfo, pbAll] = im2superpixels(im2uint8(data.images), double(planeData.planeMap));
  
  pm = zeros([size(data.depths) 4]);
  % structure class classifier
  for ii=1:5
    if opt.debug, fprintf('Merging Level %d..', ii);end
    [regionInteriors, regionBorders] = get_region_components(boundaryInfo);
    featureData = compile_boundary_classifier_feature_struct(boundaryInfo, planeData, im2uint8(data.images), pbAll);
    features2d = get_features_2d(boundaryInfo, featureData, data.images, regionInteriors, regionBorders);
    features3d = get_features_3d(boundaryInfo, featureData, points3d, normals, regionInteriors);
    boundaryFeatures = [features2d features3d];
    % boundary classifier
    load([fileparts( mfilename('fullpath') ) '/model/classifier_type3_stg1.mat'], 'classifier');
    result = merge_regions(boundaryInfo, boundaryFeatures, classifier, ii, params);
    boundaryInfo = update_boundary_info(boundaryInfo, result, data.images);
    if ii==1 % stage1 segmentation for proposal
      data.baseResult = result;
      data.baseSeg = boundaryInfo;
    end
    if opt.debug, fprintf('Classifying..\n');end
    % region classifier
    nnclassifier = load( [fileparts( mfilename('fullpath') ) '/model/classifier_src1_set0_stage' int2str(ii) '.mat']);
    R = boundaryInfo.nseg; [H, W] = size(data.depths); regionMasks = false(H, W, R);
    for rr = 1 : R
      regionMasks(:,:,rr) = boundaryInfo.imgRegions == rr;
    end
    feat = extract_region_to_structure_classes_features(im2uint8(data.images), data.depths, planeData, regionMasks);
    feat = normalize_zero_mean(feat, nnclassifier.trainMeans);
    feat = normalize_unit_var(feat, nnclassifier.trainStds);
    [accTest, cmTest, ranksTest, output] = nn_eval(nnclassifier.nn, feat, ones(size(feat,1), 1));
    seg = boundaryInfo.imgRegions; t = output(seg, :);
    t=reshape(t, [size(seg) 4]); pm = pm+t;
  end
  data.pm=pm/5;
  % visualize
  
  if opt.debug, figure(2), clf, imshow(data.pm(:,:,1:3)); end
end

function features = get_features_2d(boundaryInfo, X, imgRgb, regionInteriors, regionBorders)

  ind = 1 : boundaryInfo.ne;
  N = numel(ind);
  
  features = zeros(N,13);

  spLR = boundaryInfo.edges.spLR;
  s1 = spLR(ind, 1);
  s2 = spLR(ind, 2);
  
  imgRgb = reshape(imgRgb, [], 3);
  
  %% Edge features
  features(:,1) = X.edge.pb(ind);

  perim = zeros(boundaryInfo.nseg, 1);
  for ii = 1 : numel(X.edge.length)
    perim(spLR(ii, 1)) = perim(spLR(ii, 1)) + X.edge.length(ii);
    perim(spLR(ii, 2)) = perim(spLR(ii, 2)) + X.edge.length(ii);
  end
  minperim = min([perim(s1) perim(s2)], [], 2);
  
  features(:,2) = X.edge.length(ind) ./ minperim; % edge length / perim of smaller region
  features(:,3) = min(X.edge.smoothness(ind),1); % measure of smoothess

  % Relative angle (continuity)
  theta1 = mod(X.edge.thetaStart*180/pi, 360);
  theta2 = mod(X.edge.thetaEnd*180/pi, 360);
  maxc = zeros(N, 2);
  eadj = boundaryInfo.edges.adjacency;
  ne = boundaryInfo.ne;
  for k = 1:N
    ki = ind(k);
    ra = abs(theta2(ki)-theta1(eadj{ki}));
    ra = ra - 180*(ra>180);
    if isempty(ra), maxc(k,1) = 0;
      else maxc(k,1) = min(ra);
    end    
    ra = mod(abs(theta2(ne+ki)-theta1(eadj{ne+ki})), 180+1E-5);         
    if isempty(ra), maxc(k,2) = 0;
      else maxc(k,2) = min(ra);
    end    
  end
  features(:,[4 5]) = [min(maxc, [], 2) max(maxc, [], 2)];

  %% area2d features
  area1 = X.region.area(s1);
  area2 = X.region.area(s2);
  
  features(:, [6 7]) = [min([area1 area2], [], 2) max([area1 area2], [], 2)];
  
  %% color features
  
  % TODO: why is this commented out?
%   ch = X.region.colorHist+1E-10;
%   
%   for ii = 1 : N
%     h1 = ch(s1(ii), :);
%     e1 = sum(-log(h1) .* h1);
%     h2 = ch(s2(ii), :);
%     e2 = sum(-log(h2).*h2);
%     e12 = (area1(ii) * e1 + area2(ii)*e2) / (area1(ii) + area2(ii));
%     h3 = (area1(ii) * h1 + area2(ii)*h2) / (area1(ii) + area2(ii));
%     e3 = sum(-log(h3).*h3);
%     features(:,8) = e3 - e12;
%   end

  % Convert to YCbCr image.
  imgYCbCr = rgb2ycbcr(imgRgb);

  imgHsv = rgb2hsv(imgRgb);
  imgValue = imgHsv(:,3);
  
  % Calculate the interior and border mean and std values, this is useful for
  % detecting true vs. false edges.
  meanValuesInterior = zeros(boundaryInfo.nseg, 3);
  stdValuesInterior = zeros(boundaryInfo.nseg, 3);
  interiorStdValues = zeros(boundaryInfo.nseg, 1);
  
  meanValuesBorder = zeros(boundaryInfo.nseg, 3);
  stdValuesBorder = zeros(boundaryInfo.nseg, 3);
  borderStdValues = zeros(boundaryInfo.nseg, 1);
  
  for ii = 1 : boundaryInfo.nseg
    meanValuesInterior(ii,:) = mean(imgYCbCr(regionInteriors(:,:,ii),:),1);
    stdValuesInterior(ii,:) = std(imgYCbCr(regionInteriors(:,:,ii),:),1);
    interiorStdValues(ii) = std(imgValue(regionInteriors(:,:,ii)));
    
    meanValuesBorder(ii,:) = mean(imgYCbCr(regionBorders(:,:,ii),:),1);
    stdValuesBorder(ii,:) = std(imgYCbCr(regionBorders(:,:,ii),:),1);
    borderStdValues(ii) = std(imgValue(regionBorders(:,:,ii)));
  end
  
  % Region Color Interior Means.
  features(:,8) = sqrt(sum((meanValuesInterior(s1,:) - meanValuesInterior(s2,:)).^2,2));

  % Region Color Interior Stds.
  features(:,9) = sqrt(sum((stdValuesInterior(s1,:) - stdValuesInterior(s2,:)).^2,2));
  
  % Region Color Border Means.
  features(:,10) = sqrt(sum((meanValuesBorder(s1,:) - meanValuesBorder(s2,:)).^2,2));
  
  % Region Color Border Stds.
  features(:,11) = sqrt(sum((stdValuesInterior(s1,:) - stdValuesInterior(s2,:)).^2,2));

  features(:,12) = abs(interiorStdValues(s1) - interiorStdValues(s2));
  features(:,13) = abs(borderStdValues(s1) - borderStdValues(s2));
end


% Returns features extracted from the 3D (D) image only.
function features = get_features_3d(boundaryInfo, X, points3d, normals, ...
    regionInteriors)

  ind = 1:boundaryInfo.ne;
  N = numel(ind);
  
  features = zeros(N, 38, 'single');
  
  spLR = boundaryInfo.edges.spLR;
  s1 = spLR(ind, 1);
  s2 = spLR(ind, 2);
  
  %% First, grab a subset of 3D points from each region.
  samplePoints = cell(boundaryInfo.nseg, 1);
  basePoints = cell(boundaryInfo.nseg, 1);
  
  for ii = 1 : boundaryInfo.nseg
    regionMask = regionInteriors(:,:,ii);
    if nnz(regionMask) < 3
      regionMask = boundaryInfo.imgRegions == ii;
    end
    
    samplePoints{ii} = get_pcd_sample(points3d(regionMask, :), 100, .9);
    basePoints{ii} = mean(samplePoints{ii});
  end
  
  %% Volume3d features.
  % XYZ and XZ overlap and distance
  areaxz = (X.region.X(:, 3)-X.region.X(:, 1)).*(X.region.Z(:, 3)-X.region.Z(:, 1));
  vol = areaxz .* (X.region.Y(:, 3)-X.region.Y(:, 1));
  X1 = max(X.region.X(s1,1), X.region.X(s2,1)); X2 = min(X.region.X(s1,3), X.region.X(s2,3));
  Y1 = max(X.region.Y(s1,1), X.region.Y(s2,1)); Y2 = min(X.region.Y(s1,3), X.region.Y(s2,3));
  Z1 = max(X.region.Z(s1,1), X.region.Z(s2,1)); Z2 = min(X.region.Z(s1,3), X.region.Z(s2,3));

  intersectArea = (X2-X1).*(Z2-Z1) .* ((X2>X1) & (Z2>Z1));
  intersectVolume = intersectArea .* (Y2-Y1) .* (Y2>Y1);
  
  features(:, 1) = intersectVolume ./ min(vol(s1), vol(s2)); % volume intersection over smaller volume   
  dX = (X1-X2).^2 .*(X1>X2); dY = (Y1-Y2).^2 .* (Y1>Y2); dZ = (Z2-Z2).^2 .* (Z1>Z2);
  
  densities = zeros(boundaryInfo.nseg, 1);
  volumes = zeros(boundaryInfo.nseg, 1);
  baseAreas = zeros(boundaryInfo.nseg, 1);
  heights = zeros(boundaryInfo.nseg, 1);
  
  for ii = 1 : boundaryInfo.nseg
    boundingBox = get_bounding_box_3d(samplePoints{ii}, false);
    volumes(ii) = prod(2 * boundingBox.coeffs);
    densities(ii) = nnz(regionInteriors(:,:,ii)) / volumes(ii);
    
    baseAreas(ii) = prod(2 * boundingBox.coeffs(1:2));
    heights(ii) = 2 * boundingBox.coeffs(3);
  end
  
  maxVolumes = max([volumes(s1) volumes(s2)], [], 2);
  minVolumes = min([volumes(s1) volumes(s2)], [], 2);
  
  features(:, 2) = abs(densities(s1) - densities(s2));
  features(:, 3) = maxVolumes ./ minVolumes;
  
  
  %% Geometry features
  features(:, 4) = sqrt(dX+dY+dZ); % 3D distance between bounding boxes
  
  distXZ = (X.region.X(s1, 2)-X.region.X(s2, 2)).^2 + (X.region.Z(s1, 2)-X.region.Z(s2, 2)).^2;
  features(:, 5) = sqrt(distXZ + (X.region.Y(s1, 2)-X.region.Y(s2, 2)).^2); % distance between centroids
  
  features(:, 6) = intersectArea ./ min(areaxz(s1), areaxz(s2)); % area intersection over smaller area
  features(:, 7) = sqrt(dX + dZ); % floor plane (X-Z) distance between bounding boxes
  features(:, 8) = sqrt(distXZ);  % distance between X-Z centroids
  
  %% Fit surface normals to each region.
  
  % compute goodness of fit for sample from one region to plane of another
  npts = size(X.region.sample3D, 2)/4;
  for k = 1 : N
    pts3d1 = reshape(X.region.sample3D(s1(k), :), [npts 4]);
    pts3d2 = reshape(X.region.sample3D(s2(k), :), [npts 4]);
    features(k, 9) = (sum(abs(X.region.planeparam(s2(k), :)*pts3d1'))/npts)/X.region.Z(s1(k), 1) + ...
      (sum(abs(X.region.planeparam(s1(k), :)*pts3d2'))/npts)/X.region.Z(s2(k), 1);
  end
  
  % We should really be using a single metric for surface normal here,
  % either this or X.region.norms3d (see above and
  % compile_feature_struct.m).
  %
  % The difference between X.region.norms3d and this is that
  % X.region.norms3d is the absolute value of info3d.norms3d which benefits
  % from Derek's aligned normals. This DOESNT. We might consider 'fixing'
  % or moving the actual 3D points accordingly to the aligned normals in
  % the future.
  
  % Surface normal differences
  features(:,10) = sum(abs(X.region.norms3d(s1, 1:3)-X.region.norms3d(s2, 1:3)), 2);

  % Surface normal category differences
  features(:,11:17) = abs(X.region.norms3d(s1, 4:10)-X.region.norms3d(s2, 4:10));
  features(:,18) = sum(abs(features(:,2:8)), 2);

  % Difference in plane labels
  features(:,19) = sum(abs(X.region.planes(s1, :)-X.region.planes(s2, :)), 2);
  
  
  surfaceNormals = zeros(boundaryInfo.nseg, 3);
  for ii = 1 : boundaryInfo.nseg
    surfaceNormals(ii,:) = fit_plane_pca(samplePoints{ii});
    surfaceNormals(ii,:) = flip_normals_towards_interior(basePoints{ii}, surfaceNormals(ii,:));    
  end
  
  % Compute goodness of fit within each region.
  for ii = 1 : N
    % Fit from Region 1 to Region 1.
    centroid = mean(samplePoints{s1(ii)});
    normal = surfaceNormals(s1(ii),:);
    [~, errors1] = get_planar_disparity(samplePoints{s1(ii)}, normal, centroid);
    
    % Fit from Region 2 to Region 2.
    centroid = mean(samplePoints{s2(ii)});
    normal = surfaceNormals(s2(ii),:);
    [~, errors2] = get_planar_disparity(samplePoints{s2(ii)}, normal, centroid);
    
    % Difference in Mean errors.
    features(ii, 20) = (mean(abs(errors1)) - mean(abs(errors2))).^2;
    
    % Difference in Median errors.
    features(ii, 21) = (median(abs(errors1)) - median(abs(errors2))).^2;
    
    % Difference in Max errors.
    features(ii, 22) = (max(abs(errors1)) - max(abs(errors2))).^2;
  end
  
  %% Compute goodness of fit from one region to another (#2)
  % TODO: figure out why this seems to help a bit over the goodness of fit
  % measurement above.
  
  % Takes about .2 seconds
  for ii = 1 : N
    % Fit from Region 1 to Region 2.
    centroid = mean(samplePoints{s2(ii)});
    normal = surfaceNormals(s2(ii),:);
    [~, errors1] = get_planar_disparity(samplePoints{s1(ii)}, normal, centroid);
    
    % Fit from Region 2 to Region 1.
    centroid = mean(samplePoints{s1(ii)});
    normal = surfaceNormals(s1(ii),:);
    [~, errors2] = get_planar_disparity(samplePoints{s2(ii)}, normal, centroid);
    
    % Sum of Mean errors.
    features(ii, 23) = mean(abs(errors1)) + mean(abs(errors2));
    
    % Sum of Median errors.
    features(ii, 24) = median(abs(errors1)) + median(abs(errors2));
    
    % Sum of Max errors.
    features(ii, 25) = median(abs(errors1)) + median(abs(errors2));
  end
  
  %% 3d location features.
  mins = zeros(boundaryInfo.nseg, 1);
  maxs = zeros(boundaryInfo.nseg, 1);
  
  for ii = 1 : boundaryInfo.nseg
    mins(ii) = min(samplePoints{ii}(:,3));
    maxs(ii) = max(samplePoints{ii}(:,3));
  end
  
  minPoint = min(points3d(:,3));
  
  % Min,Max of region 1.
  features(:, 26) = min([mins(s1) - min(minPoint), mins(s2) - min(minPoint)], [], 2);
  features(:, 27) = max([maxs(s1) - min(minPoint), maxs(s2) - min(minPoint)], [], 2);
  
  %% 3d size
  % Ratio of height to base area.
  ratios = heights ./ baseAreas;
  maxRatios = max([ratios(s1) ratios(s2)], [], 2);
  minRatios = min([ratios(s1) ratios(s2)], [], 2);
  
  features(:, 28) = maxRatios;
  features(:, 29) = minRatios;
  
  
  %% Measure the distribution of surface normals.
  [~, inclinations, azimuths] = cart2sphere(normals(:,1), normals(:,2), normals(:,3));
  
  incBins = linspace(0, pi, 5);
  azBins = linspace(0, 2*pi, 5);
  
  [regionInclinations regionAzimuths] = get_surface_normal_hist(boundaryInfo.imgRegions, ...
    inclinations, incBins(1:end-1), azimuths, azBins(1:end-1));
  
  % Normalize to be a distribution.
  regionInclinations = regionInclinations ./ repmat(sum(regionInclinations,2), [1 4]);
  regionAzimuths = regionAzimuths ./ repmat(sum(regionAzimuths,2), [1 4]);

  % Difference in inclination distribution.
  features(:, 30:33) = abs(regionInclinations(s1,1:4) - regionInclinations(s2,1:4));
  features(:, 34:37) = abs(regionAzimuths(s1,1:4) - regionAzimuths(s2,1:4));
  features(:, 38) = sum(features(:, 30:33),2) + sum(features(:, 30:33),2);
end

