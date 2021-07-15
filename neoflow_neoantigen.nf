#!/usr/bin/env nextflow

params.help = false
params.netmhcpan_dir = null
params.var_db = null
params.var_info_file = null
params.out_dir = "./"
params.hla_type = null
params.prefix = "neoflow"
params.cpu = 6
params.ref_db = null
params.var_pep_file = "-"
params.var_pep_info = "-"


def helpMessage() {
    log.info"""
    =========================================
    neoflow => Neoantigen prediction
    =========================================
    Usage:
    nextflow run neoflow_neoantigen.nf
    Mandatory arguments:
      --var_db                  Variant (somatic) database in fasta format generated by neoflow_db.nf
      --var_info_file           Variant (somatic) information in txt format generated by neoflow_db.nf
      --ref_db                  Reference (known) protein database
      --hla_type                HLA typing result in txt format generated by Optitype
      --netmhcpan_dir           NetMHCpan 4.0 folder
      --var_pep_file            Variant peptide identification result generated by neoflow_msms.nf, optional.
      --var_pep_info            Variant information in txt format for customized database used for variant peptide identification
      --prefix                  The prefix of output files
      --out_dir                 Output directory
      --cpu                     The number of CPUs
      --help                    Print help message

    """.stripIndent()
}


// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}


output_prefix = params.prefix
hla_type_file = file(params.hla_type)
var_db = file(params.var_db)
var_info_file = file(params.var_info_file)
out_dir = file(params.out_dir)
netmhcpan_dir = file(params.netmhcpan_dir)
cpu = params.cpu
ref_db = file(params.ref_db)
var_pep_file = file(params.var_pep_file)
var_pep_info = file(params.var_pep_info)

/*
 * validate input files
 */
netmhcpan_tool = file(params.netmhcpan_dir + "/netMHCpan")
if( !netmhcpan_tool.exists() ) exit 1, "netMHCpan is invalid: ${netmhcpan_tool}"

if(!out_dir.isDirectory()){
    out_dir_result = out_dir.mkdirs()
    println out_dir_result ? "Create folder: $out_dir!" : "Cannot create directory: $myDir!"
}


process split_file {
    tag "split_file"

    container "proteomics/pga:latest"

    input:
    file var_info_file

    output:
    file("var_info_*") into var_info_file_list mode flatten

    script:
    """
    #!/usr/bin/env /usr/local/bin/Rscript

    library(dplyr)
    library(readr)
    library(parallel)

    ncpu <- detectCores()
    use_ncpu <- 1
    user_ncpu <- as.numeric("${cpu}")
    if(user_ncpu <= ncpu){
      use_ncpu <- user_ncpu
    }
    if(use_ncpu <= 0){
      use_ncpu <- ncpu
    }
    a <- read_tsv("${var_info_file}")

    if(use_ncpu > nrow(a)){
        ## file is small
        use_ncpu <- 1
    }

    #nlines_per_file <- ceiling(nrow(a)/use_ncpu)
    nlines_per_file <- nrow(a) %/% use_ncpu
    last_i <- 0
    for(i in 1:use_ncpu){
        i1 <- last_i + 1
        if(i < use_ncpu){    
            i2 <- i1 + nlines_per_file - 1
        }else{
            i2 <- nrow(a)
        }
        write_tsv(a[i1:i2,], paste("var_info_",i,sep=""))
        last_i <- i2
    }

    """

}


process mhc_peptide_binding_prediction {
    tag "${var_info_file_list}"

    //publishDir "${out_dir}", mode: "copy", overwrite: true
    //maxForks $cpu
    cpus 1

    container "proteomics/neoflow:latest"
    
    input:
    file hla_type_file
    file var_db
    file var_info_file_list
    file netmhcpan_dir

    output:
    file("${var_info_file_list}_binding_prediction_result.csv") into mhc_binding_prediction_i
    file("${var_info_file_list}_binding_prediction_result.csv") into mhc_binding_prediction_i_for_filtering

    script:
    """
    python ${baseDir}/bin/binding_prediction.py \
      -p ${var_info_file_list} \
      -hla_type ${hla_type_file} \
      -var_db ${var_db} \
      -var_info ${var_info_file_list} \
      -o ./ \
      -netmhcpan "${netmhcpan_dir}/netMHCpan" \
    """

}


process combine_prediction_results {
    tag "combine_prediction_results"

    container "proteomics/pga:latest"

    input:
    file "*_binding_prediction_result.csv" from mhc_binding_prediction_i.collect()

    output:
    file("${output_prefix}_binding_prediction_result.csv") into mhc_binding_prediction_file
    file("${output_prefix}_binding_prediction_result.csv") into mhc_binding_prediction_file_for_filtering

    script:
    """
    #!/usr/bin/env /usr/local/bin/Rscript
    library(dplyr)
    library(readr)
    fs <- list.files(path="./",pattern="*_binding_prediction_result.csv")
    a <- lapply(fs,read.csv,stringsAsFactors=FALSE, colClasses=c("Ref"="character", "Alt"="character","AA_before"="character","AA_after"="character")) %>% bind_rows()
    ofile <- paste("${output_prefix}","_binding_prediction_result.csv",sep="")
    write_csv(a, ofile)
    """

}

/*
 * map neoepitopes to reference protiens and remove
 * neoepitopes who can map to a reference protein.
 * data preparation
 */
process prepare_data_for_mapping {
    tag "map_to_reference"  

    container "proteomics/pga:latest"

    input:
    file mhc_binding_prediction_file

    output:
    file("all_neoepitope.txt") into all_neoepitope_file

    script:
    """
    #!/usr/bin/env /usr/local/bin/Rscript
    library(dplyr)
    library(readr)
    a <- read_csv("${mhc_binding_prediction_file}")
    pep <- a %>% select(Neoepitope) %>% distinct()
    write_tsv(pep,"all_neoepitope.txt",col_names=FALSE)
    """

}


/*
 * map neoepitopes to reference protiens and remove
 * neoepitopes who can map to a reference protein.
 * mapping
 */
process peptide_mapping {
    tag "peptide_mapping"  

    container "proteomics/neoflow:latest"

    input:
    file all_neoepitope_file
    file ref_db

    output:
    file("pep2pro.tsv") into pep2pro_file

    script:
    """
    java -jar /opt/pepmap.jar -i ${all_neoepitope_file} -d ${ref_db} -o pep2pro.tsv
    """

}

/*
 * map neoepitopes to reference protiens and remove
 * neoepitopes who can map to a reference protein.
 * filtering
 */
process filtering_by_reference {
    tag "map_to_reference"  

    container "proteomics/pga:latest"

    input:
    file pep2pro_file
    file mhc_binding_prediction_file_for_filtering

    output:
    file("${output_prefix}_neoepitope_filtered_by_reference.csv") into mhc_binding_prediction_filtered_file

    script:
    """
    #!/usr/bin/env /usr/local/bin/Rscript
    library(dplyr)
    library(readr)
    a <- read_csv("${mhc_binding_prediction_file_for_filtering}")
    pep2pro <- read_tsv("${pep2pro_file}")
    a_filter <- a %>% filter(!(Neoepitope %in% pep2pro\$peptide))
    write_csv(a_filter,"${output_prefix}_neoepitope_filtered_by_reference.csv")
    """

}

if(var_pep_file.exists() && var_pep_info.exists()){

    process add_variant_pep_evidence {
        tag "add_variant_pep_evidence"

        container "proteomics/pga:latest"

        publishDir "${out_dir}/neoantigen_prediction/", mode: "copy", overwrite: true

        input:
        file mhc_binding_prediction_filtered_file
        file var_pep_file
        file var_pep_info

        output:
        file("${output_prefix}_neoepitope_filtered_by_reference_add_variant_protein_evidence.tsv") into final_res

        script:
        """
        #!/usr/bin/env /usr/local/bin/Rscript
        library(dplyr)
        library(readr)
        library(tidyr)

        a <- read.csv("${mhc_binding_prediction_filtered_file}",stringsAsFactors=FALSE) %>%
          mutate(Chr = as.character(Chr), 
                 Start = as.character(Start), 
                 End = as.character(End), 
                 Ref = as.character(Ref),
                 Alt = as.character(Alt))

        var_pep_psms <- read.delim("${var_pep_file}",stringsAsFactors=FALSE)
        var_pep_info <- read.delim("${var_pep_info}",stringsAsFactors=FALSE) %>%
          mutate(Chr = as.character(Chr))

        var_pep_pro <- var_pep_psms %>% filter(pepquery==1) %>%
          select(peptide,protein) %>% distinct() %>%
          separate_rows(protein,sep=";")

        var_pep_pro_info <- merge(var_pep_pro,var_pep_info,by.x="protein",by.y="Variant_ID") %>%
          select(peptide,Chr,Start,End,Ref,Alt) %>%
          mutate(Chr = as.character(Chr), 
                 Start = as.character(Start), 
                 End = as.character(End), 
                 Ref = as.character(Ref),
                 Alt = as.character(Alt))

        a_var <- left_join(a,var_pep_pro_info,by=c("Chr","Start","End","Ref", "Alt")) %>%
          mutate(protein_var_evidence_pep=ifelse(is.na(peptide),"-",peptide)) %>%
          mutate(peptide=NULL)

        a_var %>% write_tsv("${output_prefix}_neoepitope_filtered_by_reference_add_variant_protein_evidence.tsv")

        """


    }
}










