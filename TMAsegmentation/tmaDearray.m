function tmaDearray(fileName,varargin)
ip = inputParser;
ip.addParamValue('buffer',1.5,@(x)(numel(x) == 1 & all(x > 0 )));  
ip.addParamValue('writeTiff',true,@islogical);
ip.addParamValue('writeMasks',true,@islogical);
ip.addParamValue('outputFiles',true,@islogical);
ip.addParamValue('sample','TMA',@(x)(ismember(x,{'TMA','tissue'})));
ip.addParamValue('Docker',false,@islogical);
ip.addParamValue('modelPath','',@isstr);
ip.addParamValue('outputPath','',@isstr);
ip.addParamValue('outputChan',1,@(x)(all(x > 0)));  
ip.parse(varargin{:});          
p = ip.Results;  

if nargin < 1
    fileName = [];
    [fileName, pathName] = uigetfile('*.ome.tif');
else
    [pathName,name,ext] = fileparts(fileName);
    fileName = [name ext ];
end


if (fileName == 0)
    error('You must select an image file to continue!')
end



%% read input data

modelPath = [p.modelPath 'RFmodel.mat'];
%  model = pixelClassifierTrain('Z:\IDAC\Clarence\LSP\CyCIF\TMA\trainingdata 1-32nd_1','logSigmas',[5 9 15 31],'nhoodStd',[3 7 11 25 31],'pctMaxNpixelsPerLabel',50,'adjustContrast',false);
%#function treeBagger
load(modelPath)

if contains(fileName,'ome.tif')
    I =bfGetReader([pathName filesep fileName]);
    numChan =I.getImageCount;
    sizeX = I.getSizeX;
    sizeY = I.getSizeY;
    DAPI = imread([pathName filesep fileName],numChan+1); %obtain the 2nd largest resolution of the 1st channel (assumed to be DAPI)
else
    DAPI = imread([pathName filesep fileName],p.outputChan); 
    sizeX = size(DAPI,2);
    sizeY = size(DAPI,1);
    DAPI = imresize(DAPI,0.5);
end
    
%% resize
dsFactor = 1/(2^4);%take the 2nd pyramid (for speed) and scale it down by 1/16 or 2^4. Effectively 1/32.
imagesub = imresize(DAPI,dsFactor);
usf=round(1/dsFactor*2);

if isequal(p.sample,'TMA')
    F = pcImageFeatures(double(imagesub)/65535,model.sigmas,model.offsets,model.osSigma,model.radii,...
                                    model.cfSigma,model.logSigmas,model.sfSigmas,model.ridgeSigmas,model.ridgenangs,...
                                    model.edgeSigmas,model.edgenangs,model.nhoodEntropy,model.nhoodStd);
                                [imL,classProbs] = imClassify(F,model.treeBag,100);

    %% get initial estimates of area and radius
    preMask = imfill(imgaussfilt3(classProbs(:,:,2),1.2)>0.85,'holes');
    stats=regionprops(preMask);
    medArea=prctile(cat(1,stats.Area),50);
    maxArea = prctile(cat(1,stats.Area),99);
    minArea = prctile(cat(1,stats.Area),2);
    estCoreRad= round(sqrt(medArea/pi)); 
    estCoreDiam = round(sqrt(maxArea/pi)*2*p.buffer);
    %% preprocessing                            
    fgFiltered=[];
    estCoreRad = [estCoreRad*0.6 estCoreRad*1.4];
    for iLog = 1:numel(estCoreRad)
        fgFiltered(:,:,iLog) = filterLoG(classProbs(:,:,2),estCoreRad(iLog));
    end
    maxImax = imhmax(max(fgFiltered,[],3),0.00001);
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
    
%% write tiff stacks
if  p.Docker==0
    filePrefix = fileName(1:strfind(fileName,'.')-1);
    writePath = [p.outputPath filesep filePrefix filesep 'dearray'];
    mkdir(writePath)
    maskPath = [writePath filesep 'masks'];
    mkdir(maskPath)
else
    writePath = '/output';
    maskPath = [writePath filesep 'masks'];
    mkdir(maskPath)
end


if p.outputFiles==1
    
    coreStack =cell(numCores);
    initialmask = cell(numCores);
    TMAmask=cell(numCores);
    singleMaskTMA = zeros(size(imagesub));
    maskTMA= zeros(size(imagesub));
    bbox=cell(numCores);
    masksub=cell(numCores);
    
    close all
   parfor iCore = 1:numCores
        hold on
        text(stats(iCore).Centroid(1),stats(iCore).Centroid(2),num2str(iCore),'Color','g')
        % check if x and y coordinates exceed the image size
        x(iCore)=centroids(iCore,1)-estCoreDiamX{iCore}/2;
        xLim(iCore)  = x(iCore)+estCoreDiamX{iCore};

        if xLim(iCore) > sizeX
            xLim(iCore) = sizeX;
        end
        if x(iCore)<1 
            xLim(iCore) = xLim(iCore) -x(iCore);
            x(iCore)=1;
        end

        y(iCore)=centroids(iCore,2)-estCoreDiamY{iCore}/2;
        yLim(iCore) = y(iCore)+estCoreDiamY{iCore};

        if yLim(iCore)>sizeY
            yLim(iCore) = sizeY;
        end
        if y(iCore)<1 
            yLim(iCore) = yLim(iCore) - y(iCore);
            y(iCore)=1;
        end
        %
        bbox{iCore} = [round(x(iCore)) round(y(iCore)) round(xLim(iCore)) round(yLim(iCore))];
        %% write cropped tiff stacks with optional subset of channels for feeding into UNet
        if p.writeTiff==1
            for iChan = p.outputChan
                coreStack{iCore} = imread([pathName filesep fileName],iChan,'PixelRegion',{[bbox{iCore}(2),bbox{iCore}(4)-1], [bbox{iCore}(1),bbox{iCore}(3)-1]});
            end
            tiffwriteimj(coreStack{iCore},[writePath filesep int2str(iCore) '.tif'])
        end
    
    %% segment each core and save mask files
        if p.writeMasks==1
            initialmask{iCore} = imresize(imcrop(classProbs(:,:,2),[round(x(iCore)),round(y(iCore)), ...
                round(xLim(iCore)-x(iCore)),round(yLim(iCore)-y(iCore))]/usf),size(coreStack{iCore}));
            if isequal(p.sample,'TMA')
                TMAmask{iCore} = coreSegmenterFigOutput(coreStack{iCore},'initialmask',initialmask{iCore},'activeContours','false','split','true');
            else
                TMAmask{iCore} = findCentralObject(initialmask{iCore});
            end
            masksub{iCore} = imresize(imresize(TMAmask{iCore},size(coreStack{iCore}),'nearest'),dsFactor/2,'nearest');
            tiffwriteimj(uint8(TMAmask{iCore}),[maskPath filesep int2str(iCore) '_mask.tif']);
            disp (['Segmented core ' num2str(iCore)])

        end
    end
    
    %% build mask outlines
    for iCore= 1:numCores
        singleMaskTMA(round(y(iCore)*dsFactor/2)+1:round(y(iCore)*dsFactor/2)+size(masksub{iCore},1),...
            round(x(iCore)*dsFactor/2)+1:round(x(iCore)*dsFactor/2)+size(masksub{iCore},2))=edge(masksub{iCore}>0);
        maskTMA = maskTMA + imresize(singleMaskTMA,size(maskTMA),'nearest');
        rect=bbox{iCore};
        save([writePath filesep int2str(iCore) '_cropCoords.mat'],'rect')
    end
    imagesub= imfuse(maskTMA>0,sqrt(double(imagesub)./max(double(imagesub(:)))));
    
    %% add centroid positions and labels to a summary image
    imshow(imagesub,[])
    for iCore = 1:numCores
        hold on
        text(stats(iCore).Centroid(1),stats(iCore).Centroid(2),num2str(iCore),'Color','g')
    end
    saveas (gcf,[writePath filesep 'TMA_MAP.tif'])
end

save([writePath filesep 'TMAPositions.mat'],'centroids')
