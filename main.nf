//Genome specific
params.genome = ''
params.genomes = []
params.bt2_index = params.genome ? params.genomes[ params.genome ].bt2Index ?: false : false
params.blacklist = params.genome ? params.genomes[ params.genome ].blacklist ?: false : false
params.genesList = params.genome ? params.genomes[ params.genome ].genesList ?: false : false
params.genomeInfo = params.genome ? params.genomes[ params.genome ].genomeInfo ?: false : false
params.help = false
params.citations = false



version = 0.5


def helpMessage() {
	log.info """
		=================================================
            A T A C s e q  P I P E L I N E v${version}
        =================================================
		Author: Michael J. Bale (mib4004@med.cornell.edu)
    Usage:
--input						  Path to input data (must be surrounded with quotes)

--genome					  Name of Genomes reference (current supported: mouse10 -- mm10, mouse39 -- mm39, human -- hg38)
							  For mouse, unless beginning new project, likely better to keep to mm10 (03/04/2022).

-profile                      Name of package manager system (available: docker, singularity, conda);
                              for WCM default -- singularity is recommended, but conda works while docker 
                              does not. For minimal - use conda.

--peaks		  			      Specifies to call peaks using HMMRATAC (default: --no-peaks)

--minReplicates			  Requires --peaks; minimum number of replicates required for overlapping of 
							  individual peak calls to consensus peak calls using ChIP-r.


Options:

--executorConfig              Path to config file that contains specifics for execution. 
                              Will default to WCM SCU-specific parameters. N.B. for
                              single-threaded running use --executorConfig conf/minimal.config

--singleSample                Specifies that the input is a single sample and will not generate a PCA graph

--PCATitle                    Title to be included in PCA graph; must be surrounded with quotes

--catLanes                    Tells CnRFlow to take input files and concatenate lanes into single fastq files

--name                        Project Name; cannot have whitespace characters

--addBEDFilesProfile          Path to csv file with info on additional BED files for generating
                              Sunset-style profile plots; csv format: rName,BEDPath

--addBEDFilesRefPoint         Path to csv file with info on additional BED files for generating
                              Torndao-style region profile plots; csv format: pName,BEDPath,PlusMinus,pLabel

--workDir                     Name of folder to output concatenated fastq files to (not used unless --catLanes)

--outdir                      Name of folder to output all results to (Default: results)

--genomeAssets                Home directory of where genome-specific files are. 
                              Defaults to /athena/josefowiczlab/scratch/szj2001/JLab-Flow_Genomes
	""".stripIndent()
}


def citationMessage() {
    log.info """
	Please cite the following tools if publishing a paper utilizing this pipeline:
	
	""".stripIndent()
}





/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help){
    helpMessage()
    exit 0
}

if (params.citations) {
	citationMessage()
	exit 0
}




log.info """\
		=================================================
            A T A C S E Q   P I P E L I N E v${version}
        =================================================
		Author: Michael J. Bale (mib4004@med.cornell.edu)
		
		Project ID: ${params.name}
        Genome: ${params.genome}
        Reads: ${params.input}
        Publish Directory: ${params.outdir}
        """
         .stripIndent()
		 
		 
if(params.catLanes) {

    getSampleID = {
	    (it =~ /(.+)_S\d+_L\d{3}/)[0][1]
	}
    
	Channel
	  .fromFilePairs(params.input, flat: true)
	  .map { prefix, r1, r2 -> tuple(getSampleID(prefix), r1, r2) }
	  .groupTuple()
	  .set {inFq_ch}
	

      process catLanes {
	    tag "Concatenating lanes into $params.workDir"
		publishDir "$params.workDir/$sampleID", mode: 'copy', pattern: "*.gz"
		label 'small_mem'
		
		input:
		tuple val(sampleID), path(R1), path(R2) from inFq_ch
				
		output:
		tuple val(sampleID), path("${sampleID}_*_init.fq.gz") into reads_ch
		
		script:
		"""
		zcat $R1 > ${sampleID}_R1_init.fq
		zcat $R2 > ${sampleID}_R2_init.fq
		
		gzip ${sampleID}_R1_init.fq
		gzip ${sampleID}_R2_init.fq
		"""
	  }
} else {
    Channel
      .fromFilePairs(params.input)
      .set {reads_ch}
}

notSingleSample = !params.singleSample



process trim {
	tag "Trimmomatic on ${pair_id}"
	label 'med_mem'

	input:
	tuple val(pair_id), path(reads) from reads_ch
	
	output:
	path("${pair_id}_trim.log") into trimmomaticLogs_ch
	tuple pair_id, path("${pair_id}*.fastq.gz") into trimmedReads_ch, tReadsFqc_ch

	//TODO: add -threads $task.cpus
	//TODO: look into fastp as alternative trimmer to handle poly-G artefacts
	script:
	"""
	trimmomatic PE \
	  -threads $task.cpus \
	  ${reads[0]} \
	  ${reads[1]} \
	  -baseout ${pair_id}_trim \
	  LEADING:20 TRAILING:20 SLIDINGWINDOW:4:20 2> ${pair_id}_trim.log
	
	mv ${pair_id}_trim_1P ${pair_id}_trim_R1.fastq
	mv ${pair_id}_trim_2P ${pair_id}_trim_R2.fastq
	gzip ${pair_id}_trim_R1.fastq
	gzip ${pair_id}_trim_R2.fastq
	"""
}

process fastqc {
	
	tag "FASTQC on ${sample_id}"
	label 'small_mem'
	
	input:
	tuple val(sample_id), path(reads) from tReadsFqc_ch

	output:
	path("fastqc_${sample_id}_logs") into fastqc_ch

	script:
	"""
	mkdir fastqc_${sample_id}_logs
	fastqc -o fastqc_${sample_id}_logs -f fastq -q ${reads}
	"""  
} 

process bowtieAlign {
	tag "Aliging $pair_id to ${params.bt2_index}"
	label 'big_mem'

	input:
	val(idx) from params.bt2_index
	tuple val(pair_id), path(reads) from trimmedReads_ch

	output:
	path("${pair_id}_bt2.log") into bt2Logs_ch
	tuple pair_id, file("${pair_id}_init.bam") into bt2Bam_ch

	//TODO: add -p $task.cpus
	script:
	"""
	bowtie2 -p $task.cpus -x ${idx} --no-mixed --no-unal --no-discordant --local --very-sensitive-local -X 1000 -k 4 --mm -1 ${reads[0]} -2 ${reads[1]} 2> ${pair_id}_bt2.log | samtools view -bS -q 30 - > ${pair_id}_init.bam
	"""

}


process filterPrimaryAln {

	tag "Filtering ${sampleID}"
	publishDir "$params.outdir/finalBam", mode: 'copy', pattern: "*.bam"
	label 'big_mem'

	input:
	path(blacklist) from params.blacklist
	tuple val(sampleID), path(bam) from bt2Bam_ch

	output:
	path("${sampleID}_idxstats.log") into idxstats_ch
	path("${sampleID}_insertSizes.log") into picardISStats_ch
	path("${sampleID}_dups.log") into picardDupStats_ch
	tuple sampleID, file("${sampleID}_final.bam") into finalBam_ch, bamForPeaks_ch
	file("${sampleID}_final.bam") into forPCA_ch, forBEPImage_ch
	val(sampleID) into names_ch
	
	//TODO: modify script for CLI arg $4 to be $task.cpus
	script:
	"""
	processAln.sh PE ${sampleID} ${bam} ${blacklist} ${task.cpus}
	"""

}

if(params.peaks) {
    process callHMMRATAC {
	    tag "Calling peaks using HMMRATAC"
		publishDir "$params.outdir/peakcalls/HMMRATACCalls-narrowPeak", mode: 'copy', pattern: '*.narrowPeak'
		label 'largeStore'
		
		
		input:
		tuple val(sampleID), path(bam) from bamForPeaks_ch
		path(genomeInfo) from params.genomeInfo
		
		
		
		output:
		tuple sampleID, file("${sampleID}_peaks.narrowPeak") into narrowPeaks_ch
				
		script:
		"""
		sambamba index ${bam}		
		java -jar ${baseDir}/bin/HMMRATAC_V1.2.10_exe.jar -b ${bam} -i ${sampleID}_final.bam.bai -g ${genomeInfo} -o ${sampleID}
		awk -v OFS='\t' '{print \$1, \$2, \$3, \$4, "1", "1", \$13, "-1", "-1"}' ${sampleID}_peaks.gappedPeak > ${sampleID}_peaks.narrowPeak
		"""
	}
	
	if(params.minReplicates > 0) {
	    getGroupID = {
			(it =~ /(.+)\.rep\d+/)[0][1]
		}
		
		narrowPeaks_ch
		  .map{ groupID, peakFile -> tuple(getGroupID(groupID), peakFile) }
		  .groupTuple()
		  .set { groupedNarrowPeaks_ch}
		
		process ChIPr {
		    tag "Finding $groupID consensus peaks with ChIP-r"
			publishDir "$params.outdir/peakcalls/", mode: 'copy', pattern: '*optimal*'
			label 'med_mem'
			
			input:
			tuple val(groupID), path(narrowPeaks)
			
			output:
			file("${groupID}_optimalPeaks.bed")
			
			script:
			"""
			ChIP-r -i ${narrowPeaks} -o ${groupID} -m 2 --rankmethod signalvalue
			"""
		}
		
		
	}
  
}



process makeBigwig{

	tag "Creating ${sampleID} bigwig"
	publishDir "$params.outdir/bigwig", mode: 'copy'
	label 'big_mem'

	input:
	tuple val(sampleID), file(finalBam) from finalBam_ch
	
	output:
	tuple val(sampleID), file("${sampleID}_CPMnorm.bw") into bigwig_ch, bigwig2_ch, bigwig3_ch
	val(sampleID) into labels_ch
	file("${sampleID}_CPMnorm.bw") into forGEnrichPlot_ch

	//TODO: add -p $task.cpus
	script:
	"""
	sambamba index $finalBam
	bamCoverage -p $task.cpus --bam ${finalBam} -o ${sampleID}_CPMnorm.bw -bs 10 --extendReads --smoothLength 50 --normalizeUsing CPM --ignoreForNormalization chrX chrY  --skipNonCoveredRegions 
	"""
}

BEFPDF_ch = names_ch.toSortedList()
sortedNamedBam = forBEPImage_ch.toSortedList()


process generateGlobalFragmentPDF {
	tag "Creating Summary Fragment Histograms"
	publishDir "$params.outdir/results", mode: 'copy'
	label 'med_mem'

	input:
	path(files) from sortedNamedBam
	val(labels) from BEFPDF_ch
	val(name) from params.name

	output:
	file( "${name}_PEFragHist-all.pdf" )
	
	//TODO: add -p $task.cpus
	script:
	"""
	for i in $files; do
	  sambamba index \$i
	done
	bamPEFragmentSize -p $task.cpus -b ${files} -o ${name}_PEFragHist-all.pdf --samplesLabel ${labels}
	"""
}

if (notSingleSample) {
process  plotPCA {
	tag "Creating bin-based Multi-Bam Summary"
	publishDir "$params.outdir/results", mode: 'copy'
label 'massive_mem'

	input:
	path(files) from forPCA_ch.collect()
	val(name) from params.name
	val(pcaTitle) from params.PCATitle

	output:
	file("${name}_PCA.png") into results_ch

	//TODO: add -p $task.cpus
	script:
	"""
	for i in ${files}
	do
	  sambamba index \$i
	done
	multiBamSummary bins -p $task.cpus -b $files -o ${name}_matrix.npz --smartLabels --extendReads
	plotPCA \
	  -in ${name}_matrix.npz \
	  -o ${name}_PCA.png \
	  -T "$pcaTitle"
	"""
	}
}

process multiqc {
	publishDir "$params.outdir/results", mode:'copy'
	label 'small_mem'

	input:
	path('*') from fastqc_ch
	  .mix(idxstats_ch)
	  .mix(picardISStats_ch)
	  .mix(picardDupStats_ch)
	  .mix(trimmomaticLogs_ch)
	  .mix(bt2Logs_ch)
	  .collect()
	
	output:
	path('multiqc_report.html')

	script:
	"""
	multiqc .
	"""
}








process computeMatrixDefault {
    tag "${sampleID} generating gene-wide TSS and GB profile matrices"
    label 'med_mem'
    
    input:
    tuple val(sampleID), file(bigwig) from bigwig_ch
    path(genes) from params.genesList

    output:
    tuple val(sampleID), path("${sampleID}_rpMat.npz") into tssMatrixGW_ch
    tuple val(sampleID), path("${sampleID}_srMat.npz") into profileMatrixGW_ch
    file("${sampleID}_rpMat.npz") into tssMatrixglob_ch
    file("${sampleID}_srMat.npz") into srMatrixglob_ch

	//TODO: add -p $task.cpus
    script:
    """
    computeMatrix reference-point -p $task.cpus  -S $bigwig -R $genes -o ${sampleID}_rpMat.npz -b 3000 -a 3000 --missingDataAsZero --samplesLabel ${sampleID}
    computeMatrix scale-regions -p $task.cpus -S $bigwig -R $genes -o ${sampleID}_srMat.npz -m 8000 -b 3000 -a 3000 --missingDataAsZero --samplesLabel $sampleID
    """
}




process generateEnrichPlots {
    tag "${sampleID} TSS and Gene-body Enrichment"
    publishDir "${params.outdir}/results/${sampleID}", mode: 'copy', pattern: "*.pdf"
    label 'small_mem'

    input:
    tuple val(sampleID), file(matrix) from tssMatrixGW_ch
    tuple val(sampleID2), file(matrix2) from profileMatrixGW_ch

    output: 
    file("${sampleID}_tssEnrich.pdf") 
    file("${sampleID}_geneBodyProfile.pdf")

    script:
    """
    plotHeatmap -m $matrix -o ${sampleID}_tssEnrich.pdf
    plotHeatmap -m $matrix2 -o ${sampleID}_geneBodyProfile.pdf
    """
}


process makeGlobalEnrichPlots {
    tag "Project: ${name} TSS and Gene Body Plots"
    publishDir "$params.outdir/results", mode: 'copy', pattern: "*.pdf"
    label 'largeStore'
    
    input:
    val(name) from params.name
    path(files) from tssMatrixglob_ch.toSortedList().collect()
    path(files2) from srMatrixglob_ch.toSortedList().collect()

    output:
    file("${name}_TSSPlot.pdf")
    file("${name}_GeneBodyPlot.pdf")
    
    script:
    """
    
    computeMatrixOperations cbind -m $files -o ${name}_TSSmat.npz
    plotHeatmap -m ${name}_TSSmat.npz -o ${name}_TSSPlot.pdf
    
    computeMatrixOperations cbind -m $files2 -o ${name}_GeneBodymat.npz
    plotHeatmap -m ${name}_GeneBodymat.npz -o ${name}_GeneBodyPlot.pdf
    """


}






if(params.addBEDFilesProfile) {
    Channel
      .fromPath(params.addBEDFilesProfile)
	  .splitCsv(header:false)
	  .map{ row -> tuple(row[0], file(row[1])) }
	  .set { extraBEDs_ch }

    extraBEDs_ch
	  .combine(bigwig2_ch)
	  .set { totalExtraBed_ch }

   
    process computeMatExtra {
        tag "Compute Matrix for ${sampleID} on extra BED file: ${extraBEDName}"
        label 'med_mem'
        
        input:
        tuple val(extraBEDName), path(BED), val(sampleID), path(bigwig) from totalExtraBed_ch

        output:
        tuple val(extraBEDName), val(sampleID), file("${sampleID}-${extraBEDName}_profile.npz") into addBEDMatTuple_ch
        tuple val(extraBEDName), file("${sampleID}-${extraBEDName}_profile.npz") into addBEDMatTupleGlobal_ch
    
		//TODO: add -p $task.cpus
        script:
        """
        computeMatrix scale-regions -p $task.cpus -S $bigwig -R $BED -b 3000 -m 8000 -a 3000 --missingDataAsZero --samplesLabel ${sampleID} -o ${sampleID}-${extraBEDName}_profile.npz
        """
    }
    


    process generateExtraBEDProfiles {
        tag "Visualizing read density for ${rName} on sample ${sName}"
        publishDir "$params.outdir/results/extraBED/${sName}", mode: 'copy'
	    label 'small_mem'

        input:
        tuple val(rName), val(sName), path(mat) from addBEDMatTuple_ch
        output:
        file("${sName}-${rName}_profile.pdf")
 
        script:
        """
        plotHeatmap -m $mat -z $rName -o "${sName}-${rName}_profile.pdf"
        """

    } 

    addBEDMatTupleGlobal_ch
      .groupTuple()
      .set { mixedExtraBEDsGT_ch }

    process generateGlobalExtraBED {
        tag "Combining profile plots for ${rName}"
        publishDir "$params.outdir/results/extraBED", mode: 'copy', pattern: "*.pdf"
	    label 'largeStore'
    
        input:
        tuple val(rName), path(mats) from mixedExtraBEDsGT_ch
        
        output:
        file("${rName}_profileAll.pdf")

        script:
        """
        computeMatrixOperations cbind -m ${mats} -o ${rName}_gMat.npz
        plotHeatmap -m ${rName}_gMat.npz -z ${rName} -o ${rName}_profileAll.pdf
        """
    }

}


if(params.addBEDFilesRefPoint) {
    Channel
      .fromPath(params.addBEDFilesRefPoint)
	  .splitCsv(header:false)
	  .map{ row -> tuple(row[0], file(row[1]), row[2], row[3]) }
	  .set { extraBEDs2_ch }

    extraBEDs2_ch
	  .combine(bigwig3_ch)
	  .set { totalExtraBed2_ch }
	  
	

   
    process computeMatExtraRP {
        tag "Compute Matrix for ${sampleID} on extra BED file: ${extraBEDName}"
	    label 'med_mem'
        
        input:
        tuple val(extraBEDName), path(BED), val(range), val(pointLabel), val(sampleID), path(bigwig) from totalExtraBed2_ch

        output:
        tuple val(extraBEDName), val(sampleID), file("${sampleID}-${extraBEDName}_refPoint.npz") into addBEDMatTuple2_ch
        tuple val(extraBEDName), file("${sampleID}-${extraBEDName}_refPoint.npz") into addBEDMatTupleGlobal2_ch
    
		//TODO: add -p $task.cpus
        script:
        """
        computeMatrix reference-point -p $task.cpus -S $bigwig -R $BED -b ${range} -a ${range} --missingDataAsZero --samplesLabel ${sampleID} -o ${sampleID}-${extraBEDName}_refPoint.npz
        """
    }
    


    process generateExtraBEDRP {
        tag "Visualizing read density for ${rName} on sample ${sName}"
        publishDir "$params.outdir/results/extraBED/${sName}", mode: 'copy'
	    label 'small_mem'

        input:
        tuple val(rName), val(sName), path(mat) from addBEDMatTuple2_ch
        output:
        file("${sName}-${rName}_refPoint.pdf")
 
        script:
        """
        plotHeatmap -m $mat --refPointLabel $rName -o "${sName}-${rName}_refPoint.pdf"
        """

    } 

    addBEDMatTupleGlobal2_ch
      .groupTuple()
      .set { mixedExtraBEDsGT2_ch }

    process generateGlobalExtraBEDRP {
        tag "Combining profile plots for ${rName}"
        publishDir "$params.outdir/results/extraBED", mode: 'copy', pattern: "*.pdf"
	    label 'largeStore'
    
        input:
        tuple val(rName), path(mats) from mixedExtraBEDsGT2_ch
        
        output:
        file("${rName}_refPointAll.pdf")

        script:
        """
        computeMatrixOperations cbind -m ${mats} -o ${rName}_gMat.npz
        plotHeatmap -m ${rName}_gMat.npz -z ${rName} -o ${rName}_refPointAll.pdf
        """
    }

}    
