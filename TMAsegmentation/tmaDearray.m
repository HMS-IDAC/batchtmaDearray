function tmaDearray(fileName,varargin)
%this function splits an .ome.tif Tissue MicroArray into individual cores
%using a trained random forest model to find the centers of each core. Each
%core is then masked through active contours. Masks and tiff files for each
%core are exported in parallel.
%Setting useGrid to true will deploy David's gridFromCentroids.m routine to
%assign an intuitive grid label to each core instead of a running number.
% Clarence Yapp & David Tallman 09/2019

ip = inputParser;
ip.addParamValue('buffer',1.2,@(x)(numel(x) == 1 & all(x > 0 )));  
ip.addParamValue('downsampleFactor',4,@(x)(numel(x) == 1 & all(x > 0 )));  
ip.addParamValue('writeTiff','true',@(x)(ismember(x,{'true','false'})));
ip.addParamValue('writeMasks','true',@(x)(ismember(x,{'true','false'})));
ip.addParamValue('outputFiles','true',@(x)(ismember(x,{'true','false'})));
ip.addParamValue('outputCenters','false',@(x)(ismember(x,{'true','false'})));
ip.addParamValue('useGrid','true',@(x)(ismember(x,{'true','false'})));
ip.addParamValue('sample','TMA',@(x)(ismember(x,{'TMA','tissue'})));
ip.addParamValue('Docker',false,@islogical);
ip.addParamValue('modelPath','',@isstr);
ip.addParamValue('outputPath','',@isstr);
ip.addParamValue('outputChan',0,@(x)(isnumeric(x))); 
ip.addParamValue('cluster',false,@islogical);
ip.parse(varargin{:});          
p = ip.Results;  

if nargin < 1
    fileName = [];
    [fileName, pathName] = uigetfile('*.ome.tif');
else
    [pathName,fileName,ext] = fileparts(fileName);
    fileName = [fileName ext ];
end


if (fileName == 0)
    error('You must select an image file to continue!')
end

if ischar(p.downsampleFactor)
    p.downsampleFactor=str2num(p.downsampleFactor);
end

%% read input data

modelPath = [p.modelPath 'model1.mat'];
%  model = pixelClassifierTrain('Z:\IDAC\Clarence\LSP\CyCIF\TMA\trainingdata 1-32nd_1','logSigmas',[5 9 15 31],'nhoodStd',[3 7 11 25 31],'pctMaxNpixelsPerLabel',50,'adjustContrast',false);
%#function treeBagger
load(modelPath)

I =bfGetReader([pathName filesep fileName]);
    numChan =I.getImageCount;
if contains(fileName,'ome.tif')
    sizeX = I.getSizeX;
    sizeY = I.getSizeY;
    DAPI = imread([pathName filesep fileName],numChan+1); %obtain the 2nd largest resolution of the 1st channel (assumed to be DAPI)
else
    DAPI = imread([pathName filesep fileName],p.outputChan); 
    sizeX = size(DAPI,2);
    sizeY = size(DAPI,1);
    DAPI = imresize(DAPI,0.5);
end

if numel(p.outputChan)==1
    if p.outputChan == 0
        p.outputChan = [1 numChan];
    else
        p.outputChan(2) = p.outputChan;
    end
end
    
%% resize
dsFactor = 1/(2^p.downsampleFactor);%take the 2nd pyramid (for speed) and scale it down by 1/16 or 2^4. Effectively 1/32.
imagesub = imresize(DAPI,dsFactor);
usf=round(1/dsFactor*2);

if isequal(p.sample,'TMA')
    F = pcImageFeatures(double(imagesub)/65535,model.sigmas,model.offsets,model.osSigma,model.radii,...
                                    model.cfSigma,model.logSigmas,model.sfSigmas,model.ridgeSigmas,model.ridgenangs,...
                                    model.edgeSigmas,model.edgenangs,model.nhoodEntropy,model.nhoodStd);
                                [imL,classProbs] = imClassify(F,model.treeBag,100);

    %% get initial estimates of area and radius
    preMask = imfill(imgaussfilt3(classProbs(:,:,2),1.2)>0.85,'holes');
    stats=regionprops(preMask,'Eccentricity','Area');
    if numel(stats)<3
        medArea=prctile(cat(1,stats.Area),50);
        maxArea = prctile(cat(1,stats.Area),99);
    else
        idx = find([stats.Eccentricity] < 0.4 & [stats.Area] > prctile(cat(1,stats.Area),5));
        stats=regionprops(ismember(bwlabel(preMask),idx));
        medArea=prctile(cat(1,stats.Area),50);
        maxArea = prctile(cat(1,stats.Area),99);
    end

    estCoreRad= round(sqrt(medArea/pi)); 
    estCoreDiam = round(sqrt(maxArea/pi)*2*p.buffer);
    %% preprocessing                            
    fgFiltered=[];
    estCoreRad = [estCoreRad*0.6 estCoreRad*1.4];
    for iLog = 1:numel(estCoreRad)
        fgFiltered(:,:,iLog) = filterLoG(classProbs(:,:,2),estCoreRad(iLog));
    end
    maxImax = imhmax(max(fgFiltered(:,:,1),[],3),0.00001);
    Imax = imregionalmax(maxImax);

    thr = thresholdOtsu(maxImax(Imax==1));
    Imax = imclearborder((maxImax>thr).*Imax);
    imshowpair(Imax,imagesub)
    centerLabel =bwlabel(Imax);
    stats=regionprops(centerLabel);
    numCores= numel(stats);
        
    centroids=cat(1,stats.Centroid).*usf;
    estCoreDiamX = num2cell(ones(numCores).*(estCoreDiam*usf));
    estCoreDiamY = num2cell(ones(numCores).*(estCoreDiam*usf));
    if strcmp(p.useGrid,'true')
        tmaGrid = gridFromCentroids(centroids,estCoreDiam,usf,'showPlots',1);
    else
        tmaGrid = [];
    end
else
    preFilt = imgaussfilt3(imagesub,2);
    mask = preFilt> thresholdMinimumError(preFilt,'model','poisson');
    mask = imfill(bwareaopen(imclose(mask,strel('square',15)),10000),'holes');
    stats=regionprops(mask);
    numCores= numel(stats);
    
    for iCore = 1:numCores
        estCoreDiamX{iCore} = stats(iCore).BoundingBox(3)*usf*p.buffer;
        estCoreDiamY{iCore} = stats(iCore).BoundingBox(4)*usf*p.buffer;
    end
    centroids=cat(1,stats.Centroid).*usf;
    classProbs=repmat(mask,[1 1 3]);
end


if numCores==0 && p.cluster
    disp('No cores detected. Try adjusting the downsample factor')
    quit(255)
end
%% write tiff stacks
if  p.Docker==0
    filePrefix = fileName(1:strfind(fileName,'.')-1);
    writePath = p.outputPath;
    mkdir(writePath)
    maskPath = [writePath filesep 'masks'];
    mkdir(maskPath)
else
    writePath = '/output';
    maskPath = [writePath filesep 'masks'];
    mkdir(maskPath)
end

if isequal(p.outputCenters ,'true')
    tiffwriteimj(uint8(imresize(Imax,[sizeY sizeX],'nearest')),[writePath filesep 'centers.tif'])
end

if isequal(p.outputFiles,'true')
    
    coreStack =cell(numCores);
    initialmask = cell(numCores);
    TMAmask=cell(numCores);
    singleMaskTMA = zeros(size(imagesub));
    maskTMA= zeros(size(imagesub));
    bbox=cell(numCores);
    masksub=cell(numCores);
    Alphabet = 'A':'Z';
    close all
    
   parfor iCore = 1:numCores
        hold on
        if ~isempty(tmaGrid)
            [row,col] = find(tmaGrid == iCore);
            gridCoord = [Alphabet(row) num2str(col)];
        else 
            gridCoord = int2str(iCore);
        end
        text(stats(iCore).Centroid(1),stats(iCore).Centroid(2),gridCoord,'Color','g')
        
        % check if x and y coordinates exceed the image size
        x(iCore)=centroids(iCore,1)-estCoreDiamX{iCore}/2;
        xLim(iCore)  = x(iCore)+estCoreDiamX{iCore};

        if xLim(iCore) > sizeX
            xLim(iCore) = sizeX;
        end
        if x(iCore)<1 
%             xLim(iCore) = xLim(iCore) -x(iCore);
            x(iCore)=1;
        end

        y(iCore)=centroids(iCore,2)-estCoreDiamY{iCore}/2;
        yLim(iCore) = y(iCore)+estCoreDiamY{iCore};

        if yLim(iCore)>sizeY
            yLim(iCore) = sizeY;
        end
        if y(iCore)<1 
%             yLim(iCore) = yLim(iCore) - y(iCore);
            y(iCore)=1;
        end
        %
        bbox{iCore} = [round(x(iCore)) round(y(iCore)) round(xLim(iCore)) round(yLim(iCore))];
        %% write cropped tiff stacks with optional subset of channels for feeding into UNet
        if isequal(p.writeTiff,'true')
            for iChan = p.outputChan(1):p.outputChan(2)
                coreStack{iCore} = cat(3,coreStack{iCore},imread([pathName filesep fileName],iChan,'PixelRegion',{[bbox{iCore}(2),bbox{iCore}(4)-1], [bbox{iCore}(1),bbox{iCore}(3)-1]}));
            end
            tiffwriteimj(coreStack{iCore},[writePath filesep gridCoord '.tif'],'dimensionOrder', 'YXCZT')
        end
    
    %% segment each core and save mask files
        if isequal(p.writeMasks,'true')
            coreSlice1 = coreStack{iCore}(:,:,1);
            initialmask{iCore} = imresize(imcrop(classProbs(:,:,2),[round(x(iCore)),round(y(iCore)), ...
                round(xLim(iCore)-x(iCore)),round(yLim(iCore)-y(iCore))]/usf),size(coreSlice1));
            if isequal(p.sample,'TMA')
                TMAmask{iCore} = coreSegmenterFigOutput(coreSlice1,'initialmask',initialmask{iCore},...
                    'activeContours','true','split','true','preBlur',mean(estCoreRad(:))/20);
            else
                TMAmask{iCore} = findCentralObject(initialmask{iCore});
            end
            if sum(sum(TMAmask{iCore} )) ==0
                TMAmask{iCore} = ones(size(TMAmask{iCore}));
            end
            masksub{iCore} = imresize(imresize(TMAmask{iCore},size(coreSlice1),'nearest'),dsFactor/2,'nearest');
            tiffwriteimj(uint8(TMAmask{iCore}),[maskPath filesep gridCoord '_mask.tif']);
            disp (['Segmented core ' gridCoord])

        end
   end

    %% build mask outlines
    maskCount = 0;
    for iCore= 1:numCores
        
        if  ~isempty(tmaGrid)
            [row,col] = find(tmaGrid == iCore);
            gridCoord = [Alphabet(row) num2str(col)];
        else 
            gridCoord = int2str(iCore);
        end
        if sum(sum(masksub{iCore}))>0
            maskCount=maskCount + 1;
        end
        singleMaskTMA(round(y(iCore)*dsFactor/2)+1:round(y(iCore)*dsFactor/2)+size(masksub{iCore},1),...
            round(x(iCore)*dsFactor/2)+1:round(x(iCore)*dsFactor/2)+size(masksub{iCore},2))=edge(masksub{iCore}>0);
        maskTMA = maskTMA + imresize(singleMaskTMA,size(maskTMA),'nearest');
        rect=bbox{iCore};
        save([writePath filesep gridCoord '_cropCoords.mat'],'rect')
    end
    imagesub= imfuse(maskTMA>0,sqrt(double(imagesub)./max(double(imagesub(:)))));
    
    if (maskCount/numCores <0.5) && p.cluster
        disp('Less than 50% of cores were segmented. Exiting.')
        quit(255)
    end
    
    %% add centroid positions and labels to a summary image
    imshow(imagesub,[])
    for iCore = 1:numCores
        hold on
        
        if  ~isempty(tmaGrid)
            [row,col] = find(tmaGrid == iCore);
            gridCoord = [Alphabet(row) num2str(col)];
        else 
            gridCoord = int2str(iCore);
        end
        text(stats(iCore).Centroid(1),stats(iCore).Centroid(2),gridCoord,'Color','g')
    end
    saveas (gcf,[writePath filesep 'TMA_MAP.tif'])
end

save([writePath filesep 'TMAPositions.mat'],'centroids')
